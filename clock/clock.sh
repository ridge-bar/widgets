#!/usr/bin/env bash
# Ridge clock plugin: a single clock (time) item. Clicking it opens macOS
# Notification Center. Split out of the calendar plugin (which now keeps
# date + meetings only) - see README.md. Talks to ridge over $RIDGE_SOCKET
# via the `ridge` CLI.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEM_ID="clock.time"

_have() { command -v "$1" >/dev/null 2>&1; }

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this script's
# own eval; the click's env assignment, script path, and settings path must
# survive both.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Builds a self-reinvoke click command: re-exec this script with the given
# env var assignment set (plus RIDGE_PLUGIN_SETTINGS forwarded via shq), so a
# click runs the action without waiting for the next poll. Mirrors the
# sibling media/mindfulness/raycast_focus plugins' build_reexec_cmd.
build_reexec_cmd() {
  local env_assignment="$1" script_path="$2" settings_path="${3:-}"
  local out="$env_assignment"
  if [[ -n "$settings_path" ]]; then
    out="RIDGE_PLUGIN_SETTINGS=$(shq "$settings_path") ${out}"
  fi
  printf '%s %s' "$out" "$(shq "$script_path")"
}

# Portable `timeout` shim: macOS ships no `timeout` binary by default.
_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# One state file under $XDG_STATE_HOME so a persistent AX failure logs once
# per failure streak instead of once per click - mirrors the sibling
# raycast_focus plugin's state-dir convention.
_clock_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/clock"
  mkdir -p "$dir" && chmod 0700 "$dir"
  printf '%s' "$dir"
}

_clock_log_ax_failure() {
  local err="$1" marker
  marker="$(_clock_state_dir)/ax_failed"
  if [[ ! -f "$marker" ]]; then
    echo "clock: opening Notification Center needs ridge granted Accessibility access (System Settings > Privacy & Security > Accessibility): $err" >&2
    : > "$marker"
  fi
}

_clock_clear_ax_warning() {
  rm -f "$(_clock_state_dir)/ax_failed"
}

# Opens macOS Notification Center by AXPress-ing the Clock menu-bar extra via
# System Events GUI scripting (verified live: this is the same mechanism
# clicking the menu bar clock triggers). Selects the item by AXIdentifier
# ("com.apple.menuextra.clock"), not its "Clock" accessibility description:
# the description string is localized (English-only), but AXIdentifier is a
# stable, locale-independent Apple-internal id - confirmed present via
# `osascript -e '... get value of attribute "AXIdentifier" of ...'` and
# confirmed to still trigger the same AXPress action. Requires ridge to be
# granted Accessibility access (System Settings > Privacy & Security >
# Accessibility); on any failure (permission denied, item not found, timeout)
# degrades silently - never surfaces an error popup - and logs at most once
# per failure streak via _clock_log_ax_failure.
_clock_open_notification_center() {
  local err
  if err="$(_timeout 5 osascript 2>&1 <<'OSA'
tell application "System Events"
  tell process "ControlCenter"
    repeat with anItem in (menu bar items of menu bar 1)
      try
        if (value of attribute "AXIdentifier" of anItem) is "com.apple.menuextra.clock" then
          perform action "AXPress" of anItem
          return
        end if
      end try
    end repeat
  end tell
end tell
OSA
  )"; then
    _clock_clear_ax_warning
    return 0
  fi
  _clock_log_ax_failure "$err"
  return 1
}

# shellcheck disable=SC2034 # SETTING_* are consumed by main(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  SETTING_time_format="$(jq -r '.time_format // "%H:%M:%S"' <<<"$json")"
  [[ -n "$SETTING_time_format" ]] || SETTING_time_format="%H:%M:%S"
  # Poll interval in seconds. Must be a positive number, else default 1 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_time_interval="$(jq -r '.time_interval // "1"' <<<"$json")"
  [[ "$SETTING_time_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_time_interval//[.0]/}" ]] || SETTING_time_interval="1"
  SETTING_label_color="$(jq -r '.label_color // "theme:primary"' <<<"$json")"
  SETTING_bg_color="$(jq -r '.bg_color // "theme:background"' <<<"$json")"
  SETTING_corner_radius="$(jq -r '.corner_radius // ""' <<<"$json")"
  if [[ -n "$SETTING_corner_radius" ]] && ! [[ "$SETTING_corner_radius" =~ ^[0-9]+$ && "$SETTING_corner_radius" -ge 0 && "$SETTING_corner_radius" -le 30 ]]; then
    SETTING_corner_radius=""
  fi
  # Empty (unset) means auto: ridge core adapts the pill height to the bar
  # height. bg_height stays a valid opt-in override; out-of-range or
  # non-numeric input resets to empty/auto rather than any fixed default.
  SETTING_bg_height="$(jq -r '.bg_height // ""' <<<"$json")"
  if [[ -n "$SETTING_bg_height" ]] && ! [[ "$SETTING_bg_height" =~ ^[0-9]+$ && "$SETTING_bg_height" -ge 16 && "$SETTING_bg_height" -le 48 ]]; then
    SETTING_bg_height=""
  fi
}

# Sketchybar-style pill geometry flags for the `ridge add` call - extracted
# so bats can assert the flags without invoking the real `ridge` CLI.
_pill_flags() {
  local out=""
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- '--bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

# Sleeps until the next wall-clock boundary of `interval` seconds, so the
# tick loop tracks real time instead of drifting by however long the
# preceding work (ridge set) took. perl(1) ships on macOS by default; falls
# back to a plain `sleep "$interval"` if perl is unavailable.
_sleep_to_boundary() {
  local interval="$1"
  perl -MTime::HiRes=time,sleep -e '
    $i = shift; $i = 1 if $i <= 0;
    $t = time();
    $r = $i - ($t - int($t / $i) * $i);
    sleep($r > 0.001 ? $r : $i);
  ' "$interval" 2>/dev/null || sleep "$interval"
}

main() {
  for dep in jq date ridge osascript; do
    if ! _have "$dep"; then echo "clock: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  load_settings

  if [[ -n "${CLOCK_OPEN_NC:-}" ]]; then
    _clock_open_notification_center
    exit 0
  fi

  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "clock: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi

  local click_cmd
  click_cmd="$(build_reexec_cmd "CLOCK_OPEN_NC=1" "${PLUGIN_ROOT}/clock.sh" "${RIDGE_PLUGIN_SETTINGS:-}")"

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors/numbers only)
  ridge add "$ITEM_ID" --region "$SETTING_region" --text "$(date +"$SETTING_time_format")" \
    --font "$SETTING_font" --color "$SETTING_label_color" --bg-color "$SETTING_bg_color" \
    --click "$click_cmd" $(_pill_flags) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    ridge set "$ITEM_ID" --text "$(date +"$SETTING_time_format")" 2>/dev/null || true

    # Aligns to the next wall-clock boundary instead of a fixed sleep, so
    # per-tick work (above) doesn't accumulate drift and skip seconds.
    _sleep_to_boundary "$SETTING_time_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so the
# guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

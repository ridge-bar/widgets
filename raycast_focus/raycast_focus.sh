#!/usr/bin/env bash
# Ridge Raycast Focus plugin: polls Raycast's menu bar item count (via System
# Events) for an active Focus session and paints the bar item accordingly.
# Clicking the item toggles the session directly via deeplink (see
# build_click_cmd) rather than waiting for the next poll. Ported from the
# sketchybar raycast_focus item/plugin pair.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEM_ID="raycast_focus.status"

_have() { command -v "$1" >/dev/null 2>&1; }

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this script's
# own eval; the click's script path and settings path must survive both.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# shellcheck disable=SC2034 # SETTING_* consumed by main()/paint_state()/toggle_and_paint(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  # Poll interval in seconds. Must be a positive number, else default 15 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "15"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="15"
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  # Icon font: the item's icon glyph is a Nerd Font glyph, so it renders
  # as tofu in the system default font unless a Nerd Font family is set
  # at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  SETTING_on_color="$(jq -r '.on_color // "theme:success"' <<<"$json")"
  SETTING_off_color="$(jq -r '.off_color // "theme:warning"' <<<"$json")"
  SETTING_glyph_color="$(jq -r '.glyph_color // "#12161D"' <<<"$json")"
  # Raycast matches categories by slug token, not display name - see the
  # comment on toggle_and_paint() and README.md.
  SETTING_categories="$(jq -r '.categories // "social---edited"' <<<"$json")"
  SETTING_mode="$(jq -r '.mode // "block"' <<<"$json")"
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

# Sketchybar-style pill background flags (corner-radius/height/padding) for
# the item's `ridge add` call - extracted so bats can assert the flags
# without invoking the real `ridge` CLI. Only corner-radius/height/padding
# here, not bg-color: on_color/off_color already serve as the
# pill color, applied separately by paint_state.
_pill_flags() {
  local out=""
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- '--bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

# Portable `timeout` shim: macOS ships no `timeout` binary by default. A
# belt-and-suspenders guard on top of the AppleScript's own internal timeout
# block, in case osascript itself hangs before that block takes effect.
_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# Pure parse of the AX query result into a state word, factored out of
# focus_state() so it's testable without shelling out to osascript. The
# AppleScript already reduces the menu bar to "on"/"off" (see _raycast_ax_count):
# an active Raycast Focus session puts a live countdown (e.g. " 00:36:28") in
# a menu bar 2 status item, whose title contains ASCII colons; idle titles
# ("No Timer", empty) have none. Counting items is NOT reliable on current
# Raycast - idle and active can both show the same count - but the countdown
# title is a definitive signal. Anything else = a well-formed call we can't map.
_raycast_count_to_state() {
  case "$1" in
  on)  printf on ;;
  off) printf off ;;
  *)   printf unknown ;;
  esac
}

# One state file under $XDG_STATE_HOME so a persistent AX failure logs once
# per failure streak instead of once per poll - mirrors the sibling
# amphetamine plugin's preflight/state-dir convention.
_raycast_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/raycast_focus"
  mkdir -p "$dir" && chmod 0700 "$dir"
  printf '%s' "$dir"
}

_raycast_log_ax_failure() {
  local err="$1" marker
  marker="$(_raycast_state_dir)/ax_failed"
  if [[ ! -f "$marker" ]]; then
    echo "raycast_focus: AX query failed - live Focus detection needs ridge granted Automation access to System Events (System Settings > Privacy & Security > Automation). Until then the widget self-tracks the state it toggles: $err" >&2
    : > "$marker"
  fi
}

_raycast_clear_ax_warning() {
  rm -f "$(_raycast_state_dir)/ax_failed"
}

# Self-tracked Focus state ("on"/"off"), the fallback signal when the AX query
# is unavailable (ridge lacks Automation access). The toggle writes it; the
# poll paints from it when AX can't be read. Atomic write (temp + mv) so the
# poll loop never reads a torn value mid-write. Default "off".
_raycast_read_tracked() {
  local f; f="$(_raycast_state_dir)/active"
  if [[ -f "$f" ]]; then cat "$f"; else printf 'off'; fi
}

_raycast_write_tracked() {
  local dir tmp; dir="$(_raycast_state_dir)"
  tmp="${dir}/.active.tmp.$$"
  printf '%s' "$1" > "$tmp" && mv -f "$tmp" "${dir}/active"
}

# Runs the AX AppleScript that decides Focus on/off from Raycast's menu bar.
# An active Focus session shows a live countdown timer in a menu bar 2 status
# item; its title contains an ASCII colon (e.g. " 00:36:28"). Idle titles have
# none. The AppleScript loops the items and returns "on" if any title contains
# ":", else "off" (deciding in AppleScript keeps the unicode countdown digits
# off the shell round-trip). Prints "on"/"off" on success (exit 0); on non-zero
# exit prints the failure reason (denied Automation, osascript timeout) instead
# of blinding it, so focus_state can warn+diagnose. `if var=$(cmd); then` (not a
# bare failing assignment) so a caller under `set -e` (bats) isn't tripped by a
# real AX/Automation failure.
_raycast_ax_count() {
  local err
  if err="$(_timeout 5 osascript 2>&1 <<'OSA'
with timeout of 3 seconds
  tell application "System Events"
    if not (exists process "Raycast") then return "off"
    tell process "Raycast"
      repeat with anItem in (menu bar items of menu bar 2)
        try
          if (title of anItem) contains ":" then return "on"
        end try
      end repeat
      return "off"
    end tell
  end tell
end timeout
OSA
  )"; then
    printf '%s' "$err" # on success $err holds stdout: "on" or "off"
    return 0
  fi
  printf '%s' "$err"
  return 1
}

# Effective Focus state, always "on" or "off" (never a warn/unknown that would
# stall the toggle or paint an ambiguous color). The AX query can only CONFIRM
# an active session, never deny one:
#   - AX succeeds with a positive "on" (Raycast shows a Focus countdown)
#     -> "on". Preserves live detection of sessions started/ended outside the
#     widget on Raycast versions whose Focus indicator exposes a countdown.
#   - AX succeeds with "off"/unknown -> NOT authoritative. Raycast's Focus
#     status item is often icon-only (no countdown), so a well-formed "off"
#     only means "not detected", not "definitely off". Fall through to the
#     self-tracked state. This is not a permission failure, so it does not log.
#   - AX fails -> fall back to tracked and log the Automation-permission warning
#     once per failure streak.
# Read-only: the tracked file is written only by the toggle, never synced from
# AX here, so a lagging AX read during a toggle can't fight the toggle's write.
focus_state() {
  local raw
  if raw="$(_raycast_ax_count)"; then
    _raycast_clear_ax_warning
    if [[ "$(_raycast_count_to_state "$raw")" == "on" ]]; then printf on; return 0; fi
  else
    _raycast_log_ax_failure "$raw"
  fi
  _raycast_read_tracked
}

# Paints the item's background color for the current state. Used on initial
# add and after every poll (and, via toggle_and_paint, right after a click).
# focus_state is always on/off, so the color is always definite.
paint_state() {
  case "$(focus_state)" in
  on)  ridge set "$ITEM_ID" --bg-color "$SETTING_on_color" 2>/dev/null || true ;;
  off) ridge set "$ITEM_ID" --bg-color "$SETTING_off_color" 2>/dev/null || true ;;
  esac
}

# Polls focus_state() every 0.5s, up to 4s total, until it settles on a
# genuine on/off state different from $before - Raycast adds/removes its
# menu bar timer asynchronously after the deeplink fires, so a single
# fixed-delay repaint can race it and leave the bar showing the pre-toggle
# color until the next scheduled poll. Returns non-zero on timeout (the
# caller still repaints with whatever state is current).
_raycast_wait_for_flip() {
  local before="$1" i now
  for ((i = 0; i < 8; i++)); do
    sleep 0.5
    now="$(focus_state)"
    if [[ ("$now" == "on" || "$now" == "off") && "$now" != "$before" ]]; then
      return 0
    fi
  done
  return 1
}

# Toggles the Focus session via deeplink. start passes no duration: the
# session runs until completed. open -g keeps the current app focused.
toggle_and_paint() {
  local before
  before="$(focus_state)"          # on/off (AX if available, else tracked)
  if [[ "$before" == "on" ]]; then
    open -g "raycast://focus/complete"
    _raycast_write_tracked off      # record intent so a stop is remembered
  else
    open -g "raycast://focus/start?goal=Work&categories=${SETTING_categories}&mode=${SETTING_mode}"
    _raycast_write_tracked on
  fi
  # If AX works, wait for it to confirm the flip so the paint reflects reality;
  # if AX is unavailable, the tracked state already flipped, so focus_state
  # returns the new value on the first poll and this returns quickly.
  _raycast_wait_for_flip "$before" || true
  paint_state
}

# Builds the --click command: re-exec this script with RAYCAST_TOGGLE=1 (and
# the current settings file, so the repaint uses the configured colors) so a
# click toggles the session and repaints in one shot. Simpler and safer than
# inlining the multi-line AppleScript as the click string.
build_click_cmd() {
  local script_path="$1" settings_path="${2:-}"
  local out="RAYCAST_TOGGLE=1"
  if [[ -n "$settings_path" ]]; then
    out="RIDGE_PLUGIN_SETTINGS=$(shq "$settings_path") ${out}"
  fi
  printf '%s %s' "$out" "$(shq "$script_path")"
}

main() {
  for dep in jq ridge osascript; do
    if ! _have "$dep"; then echo "raycast_focus: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  load_settings

  if [[ -n "${RAYCAST_TOGGLE:-}" ]]; then
    toggle_and_paint
    exit 0
  fi

  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "raycast_focus: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi

  local click_cmd
  click_cmd="$(build_click_cmd "${PLUGIN_ROOT}/raycast_focus.sh" "${RIDGE_PLUGIN_SETTINGS:-}")"

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (numbers only)
  ridge add "$ITEM_ID" --region "$SETTING_region" --text "" --icon "󰗝" --icon-color "$SETTING_glyph_color" --bg-color "$SETTING_off_color" --click "$click_cmd" --font "$SETTING_font" $(_pill_flags) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    paint_state
    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so
# the guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

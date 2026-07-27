#!/usr/bin/env bash
# Ridge Amphetamine plugin: polls `pmset -g assertions` for an active
# Amphetamine session and paints the bar item accordingly. Clicking the item
# toggles the session directly (see build_click_cmd) rather than waiting for
# the next poll. Ported from the sketchybar amphetamine item/plugin pair.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Nerd Font glyphs (U+F0176 active, U+F04B2 inactive), matching the source
# sketchybar icons exactly.
AMPH_GLYPH_ACTIVE=$'\U000f0176'
AMPH_GLYPH_INACTIVE=$'\U000f04b2'

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this script's
# own eval; the click's script path and settings path must survive both.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# shellcheck disable=SC2034 # SETTING_* consumed by main()/paint_state(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  # Icon font: AMPH_GLYPH_ACTIVE/AMPH_GLYPH_INACTIVE (rendered via --text)
  # are Nerd Font glyphs, so they render as tofu in the system default
  # font unless a Nerd Font family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  SETTING_interval="$(jq -r '.interval // "5"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="5"
  SETTING_on_color="$(jq -r '.on_color // "theme:success"' <<<"$json")"
  SETTING_off_color="$(jq -r '.off_color // "theme:warning"' <<<"$json")"
  SETTING_glyph_color="$(jq -r '.glyph_color // "#12161D"' <<<"$json")"
  # Background when the preflight check (see _amph_preflight) fails - the
  # widget refuses to toggle and needs the user's attention (grant Automation
  # access to Amphetamine in System Settings > Privacy & Security).
  SETTING_warn_color="$(jq -r '.warn_color // "theme:warning"' <<<"$json")"
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
# the item's `ridge add`/`ridge set` calls - extracted so bats can assert the
# flags without invoking the real `ridge` CLI. Only corner-radius/height/
# padding here, not bg-color: on_color/off_color/warn_color already serve as
# the pill color, applied separately by paint_state/paint_warn.
_pill_flags() {
  local out=""
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- '--bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

# Factored out so tests can stub the assertions text without shelling out to
# the real `pmset`.
_pmset_assertions() {
  pmset -g assertions 2>/dev/null
}

# Parses "true"/"false" from Amphetamine's `session is active` AppleScript
# result; prints "active", "inactive", or "" (couldn't ask). Factored out so
# bats can feed it the two literal results without invoking osascript.
_parse_session_active() {
  case "$1" in
    *true*)  printf 'active' ;;
    *false*) printf 'inactive' ;;
    *)       printf '' ;;
  esac
}

# Asks Amphetamine's scripting API whether a session is active; prints its raw
# "true"/"false" (or nothing if unreachable). Factored out so bats can stub it
# without osascript.
_ask_session_active() {
  osascript -e 'tell application "Amphetamine" to session is active' 2>/dev/null
}

# Authoritative active-session check via Amphetamine's own scripting API
# (`session is active`), NOT `pmset` regex: a single-use session drops its
# power assertion the instant it ends, so pmset races and the icon flickers
# out of sync. Falls back to the pmset assertion only if the API is
# unreachable (Amphetamine not running / Automation not granted).
is_active() {
  case "$(_parse_session_active "$(_ask_session_active)")" in
    active)   return 0 ;;
    inactive) return 1 ;;
    *)        _pmset_assertions | grep -qE '\(Amphetamine\).*Prevent' ;;
  esac
}

# Paints the item's glyph/colors for the current state. Used on initial add
# and after every poll (and, via toggle_and_paint, right after a click).
paint_state() {
  if is_active; then
    ridge set amphetamine.toggle --text "$AMPH_GLYPH_ACTIVE" --color "$SETTING_glyph_color" --bg-color "$SETTING_on_color" 2>/dev/null || true
  else
    ridge set amphetamine.toggle --text "$AMPH_GLYPH_INACTIVE" --color "$SETTING_glyph_color" --bg-color "$SETTING_off_color" 2>/dev/null || true
  fi
}

# Distinct warning state painted when the preflight check fails: the widget
# needs the user's attention (grant Automation access to Amphetamine), not
# just an on/off color.
paint_warn() {
  ridge set amphetamine.toggle --text "$AMPH_GLYPH_INACTIVE" --color "$SETTING_glyph_color" --bg-color "$SETTING_warn_color" 2>/dev/null || true
}

# One state file under $XDG_STATE_HOME so a preflight failure logs once per
# streak instead of once per click - each click is a separate re-exec'd
# process (see build_click_cmd), so an in-memory flag can't survive between
# clicks; this mirrors the sibling mindfulness plugin's state-dir convention.
_amph_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/amphetamine"
  mkdir -p "$dir" && chmod 0700 "$dir"
  printf '%s' "$dir"
}

# Verifies ridge (osascript) can actually reach Amphetamine before ever
# attempting a toggle. Amphetamine's .sdef defines no {interval:hours}
# enumerator; sending a malformed AppleEvent to an app ridge lacks TCC
# Automation approval for is exactly what darkened the displays and forced a
# re-login once already (see toggle_session) - never toggle blind. Prints
# stderr and returns non-zero on failure.
_amph_preflight() {
  local err
  # `if var=$(cmd); then` (not `var=$(cmd); status=$?`): a bare failing
  # assignment trips `set -e` in any caller/test harness that has it active
  # (bats does) and aborts before status is ever read. A command substitution
  # used as an if-condition is exempt from errexit.
  if err="$(osascript -e 'with timeout of 3 seconds' -e 'tell application "Amphetamine" to get version' -e 'end timeout' 2>&1 >/dev/null)"; then
    return 0
  fi
  printf '%s' "$err"
  return 1
}

# Toggles the Amphetamine session via AppleScript, ported verbatim from the
# sketchybar plugin. Starting with NO options makes Amphetamine use its
# Preferences default duration (set that to 8 hours in Amphetamine's
# preferences). We deliberately do NOT pass {interval:hours}: the .sdef
# defines no such enumerator, so AppleScript substitutes the constant
# `hours`=3600 and sends a malformed session, which darkened the displays and
# forced a re-login. stderr is captured (not blinded) and logged on failure -
# a caller only reaches here after _amph_preflight already succeeded, but the
# session state can still race between that check and this call.
toggle_session() {
  local err ok=0
  # `if var=$(cmd); then` per branch (not a bare failing assignment): see the
  # comment on _amph_preflight - errexit-safe either way.
  if is_active; then
    if err="$(osascript -e 'with timeout of 3 seconds
      tell application "Amphetamine" to end session
    end timeout' 2>&1 >/dev/null)"; then ok=1; fi
  else
    # Explicit options, NOT a bare `start new session`: a bare start inherits
    # Amphetamine's Preferences default, and if that default allows display
    # sleep the display darkens and the Mac hits the lock screen (looks like a
    # logout - the exact symptom reported). The sdef documents this infinite
    # form: duration 0 + interval 0 = infinite; displaySleepAllowed:false
    # keeps the screen on. interval is the integer 0 (the documented value),
    # never the bareword `hours` (which AppleScript resolves to 3600 and sends
    # malformed).
    if err="$(osascript -e 'with timeout of 3 seconds
      tell application "Amphetamine" to start new session with options {duration:0, interval:0, displaySleepAllowed:false}
    end timeout' 2>&1 >/dev/null)"; then ok=1; fi
  fi
  if [[ "$ok" -eq 0 ]]; then
    echo "amphetamine: toggle_session osascript failed: $err" >&2
  fi
  sleep 0.5 # let Amphetamine (de)register its power assertion
}

# Entry point for the --click command (AMPHETAMINE_TOGGLE=1): preflight
# before ever toggling. On success, toggle and repaint immediately instead of
# waiting up to $SETTING_interval seconds for the next poll. On failure, do
# NOT toggle - log the preflight error once per failure streak and paint the
# warning state instead.
toggle_and_paint() {
  local err marker
  marker="$(_amph_state_dir)/preflight_failed"
  if err="$(_amph_preflight)"; then
    rm -f "$marker"
    toggle_session
    paint_state
  else
    if [[ ! -f "$marker" ]]; then
      echo "amphetamine: preflight failed, refusing to toggle (grant Automation access to Amphetamine in System Settings > Privacy & Security): $err" >&2
      : > "$marker"
    fi
    paint_warn
  fi
}

# Builds the --click command: re-exec this script with AMPHETAMINE_TOGGLE=1
# (and the current settings file, so the repaint uses the configured
# colors) so a click toggles the session and repaints in one shot. Simpler
# and safer than inlining the multi-line AppleScript as the click string.
build_click_cmd() {
  local script_path="$1" settings_path="${2:-}"
  local out="AMPHETAMINE_TOGGLE=1"
  if [[ -n "$settings_path" ]]; then
    out="RIDGE_PLUGIN_SETTINGS=$(shq "$settings_path") ${out}"
  fi
  printf '%s %s' "$out" "$(shq "$script_path")"
}

main() {
  for dep in jq ridge; do
    if ! command -v "$dep" >/dev/null 2>&1; then echo "amphetamine: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  load_settings

  if [[ -n "${AMPHETAMINE_TOGGLE:-}" ]]; then
    toggle_and_paint
    exit 0
  fi

  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "amphetamine: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi

  local click_cmd
  click_cmd="$(build_click_cmd "${PLUGIN_ROOT}/amphetamine.sh" "${RIDGE_PLUGIN_SETTINGS:-}")"

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (numbers only)
  ridge add amphetamine.toggle --region "$SETTING_region" --text "$AMPH_GLYPH_INACTIVE" --color "$SETTING_glyph_color" --bg-color "$SETTING_off_color" --click "$click_cmd" --font "$SETTING_font" $(_pill_flags) || true
  trap 'ridge remove amphetamine.toggle 2>/dev/null; exit 0' TERM INT

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

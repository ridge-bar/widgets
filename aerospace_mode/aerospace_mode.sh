#!/usr/bin/env bash
# Ridge aerospace_mode plugin: an attention-colored pill showing the active AeroSpace
# binding mode (e.g. SERVICE), hidden while in the 'main' mode, positioned
# immediately before the aerospace plugin's workspace strip (TASK-90) -
# either its container id or its leading child, whichever is currently
# first, so the badge lands right after whatever precedes the strip (e.g.
# the global menu) instead of jumping to the absolute front of the region.
# Ported from sketchybar's items/aerospace_mode.sh + plugins/aerospace_mode.sh.
# AeroSpace has no query for its current binding mode and `ridge trigger`
# carries no payload, so the mode name travels via a state file the user's
# aerospace.toml mode bindings write before firing `ridge trigger
# aerospace_mode` (delivered as SIGUSR1 - see trigger_loop below). Standalone
# from plugins/aerospace/ on purpose (separate in-flight work); talks to
# ridge over $RIDGE_SOCKET via the `ridge` CLI.
set -uo pipefail

ITEM_ID="aerospace_mode.badge"

# Nerd Font gear glyph (U+F0493), matching the sketchybar source's icon.
AM_GLYPH="󰒓"

_have() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC2034 # SETTING_* consumed by main()/paint helpers, not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "left"' <<<"$json")"
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"

  # Attention badge: warning-family bg with ink-toned glyph/label -
  # keeps the urgency of the sketchybar source's red-on-dark styling.
  SETTING_bg_color="$(jq -r '.bg_color // "theme:warning"' <<<"$json")"
  SETTING_icon_color="$(jq -r '.icon_color // "#12161D"' <<<"$json")"
  SETTING_label_color="$(jq -r '.label_color // "#12161D"' <<<"$json")"

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
  SETTING_padding_left="$(jq -r '.padding_left // "8"' <<<"$json")"
  [[ "$SETTING_padding_left" =~ ^[0-9]+$ && "$SETTING_padding_left" -ge 0 && "$SETTING_padding_left" -le 40 ]] || SETTING_padding_left="8"
  SETTING_padding_right="$(jq -r '.padding_right // "8"' <<<"$json")"
  [[ "$SETTING_padding_right" =~ ^[0-9]+$ && "$SETTING_padding_right" -ge 0 && "$SETTING_padding_right" -le 40 ]] || SETTING_padding_right="8"

  # state_file defaults to a runtime-computed XDG path (YAML can't express
  # that as a literal default) - same technique as the vpn plugin's
  # netbird_bin probe.
  SETTING_state_file="$(jq -r '.state_file // ""' <<<"$json")"
  [[ -n "$SETTING_state_file" ]] || SETTING_state_file="${XDG_CACHE_HOME:-$HOME/.cache}/ridge/aerospace_mode/mode"
}

##############################################################################
# Pure functions: no I/O - directly testable.
##############################################################################

# Sanitizes raw state-file content into a safe mode name: trims whitespace,
# caps length at 24 chars, then requires the result to be entirely
# [A-Za-z0-9_-]. Prints the sanitized mode name, or nothing for empty/main/
# invalid input. Logs one stderr line only when the input was non-empty but
# failed the character allowlist (genuine garbage), not for the ordinary
# empty/main cases.
_am_sanitize_mode() {
  local raw="$1"
  # Trim leading/trailing whitespace (spaces, tabs, newlines).
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  raw="${raw:0:24}"
  if [[ -z "$raw" ]]; then
    return 0
  fi
  if [[ ! "$raw" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "aerospace_mode: state file content is not a valid mode name; treating as main (hidden)" >&2
    return 0
  fi
  printf '%s' "$raw"
}

# Uppercased label for a sanitized mode name, or empty for main/empty (the
# badge is hidden in both cases).
_am_label_for_mode() {
  local mode="$1"
  if [[ -z "$mode" || "$mode" == "main" ]]; then
    return 0
  fi
  printf '%s' "$mode" | tr '[:lower:]' '[:upper:]'
}

# Sketchybar-style pill style flags shared by `ridge add` and `ridge set`
# (bg/colors/padding). Font is add-only (not in `ridge set`'s allowed flag
# set) so it is NOT included here - see main()'s add call.
_pill_style_flags() {
  local out
  out="$(printf -- '--bg-color %s --padding-left %s --padding-right %s --icon-color %s --color %s' \
    "$SETTING_bg_color" \
    "$SETTING_padding_left" "$SETTING_padding_right" \
    "$SETTING_icon_color" "$SETTING_label_color")"
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- ' --bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

##############################################################################
# I/O: talks to the state file and ridge.
##############################################################################

_am_read_raw_mode() {
  [[ -f "$SETTING_state_file" ]] && cat "$SETTING_state_file" 2>/dev/null
  return 0
}

_am_item_exists_in() {
  local json="$1"
  jq -e --arg id "$ITEM_ID" 'any(.[]; .id == $id)' <<<"$json" >/dev/null 2>&1
}

# The aerospace plugin's own leading item, in current render order: its
# container anchor id ("aerospace", TASK-88) when the user has placed one, or
# else its leading workspace-strip child. Either way, the id this plugin is
# permitted to anchor before (declared as `permissions.anchors: [aerospace.]`
# in plugin.yaml - matches the bare prefix "aerospace" and any "aerospace."
# child). Empty when the aerospace plugin has no items yet (e.g. a startup
# race) - the caller falls back to a plain, unanchored add/set in that case,
# which the next paint (mode re-entry) corrects once aerospace has caught up.
_am_resolve_anchor_in() {
  local json="$1"
  jq -r '[.[] | select(.id == "aerospace" or (.id | startswith("aerospace.")))] | .[0].id // empty' <<<"$json"
}

_am_add_or_set() {
  local label="$1" items anchor
  items="$(ridge query items 2>/dev/null)"
  anchor="$(_am_resolve_anchor_in "$items")"
  if ! _am_item_exists_in "$items"; then
    local anchor_flag=""
    [[ -n "$anchor" ]] && { local qanchor; printf -v qanchor '%q' "$anchor"; anchor_flag=" --before $qanchor"; }
    # shellcheck disable=SC2046,SC2086 # anchor_flag is either empty or "--before <id>" (id has no whitespace/glob chars); _pill_style_flags emits space-separated --flag value pairs with no embedded whitespace
    ridge add "$ITEM_ID" --region "$SETTING_region" --icon "$AM_GLYPH" --text "$label" --font "$SETTING_font"$anchor_flag $(_pill_style_flags) 2>/dev/null || true
  else
    # shellcheck disable=SC2046 # _pill_style_flags emits space-separated --flag value pairs with no embedded whitespace
    ridge set "$ITEM_ID" --icon "$AM_GLYPH" --text "$label" $(_pill_style_flags) 2>/dev/null || true
    # Re-anchors an EXISTING badge on every paint: a displaced badge (another
    # plugin inserted ahead of it) recovers without a mode cycle. A visible
    # slide here is correct - it's recovering position, not being born. Skipped
    # when aerospace has no items yet (nothing to anchor before).
    if [[ -n "$anchor" ]]; then
      ridge move "$ITEM_ID" --before "$anchor" 2>/dev/null || true
    fi
  fi
}

# One paint pass: read the state file, sanitize, hide (remove) in main/empty/
# invalid, else add-or-set the badge with the uppercased label.
_am_paint() {
  local raw mode label
  raw="$(_am_read_raw_mode)"
  mode="$(_am_sanitize_mode "$raw")"
  label="$(_am_label_for_mode "$mode")"
  if [[ -z "$label" ]]; then
    ridge remove "$ITEM_ID" 2>/dev/null || true
    return 0
  fi
  _am_add_or_set "$label"
}

# Reconcile only on `ridge trigger aerospace_mode` (delivered as SIGUSR1) plus
# an initial paint at startup. Ported from plugins/aerospace/aerospace-plugin.sh's
# trigger_loop: the USR1 trap only sets a flag, drained at the top of the loop,
# so a signal arriving mid-paint cannot re-enter it and rapid triggers coalesce
# into one follow-up paint.
trigger_loop() {
  local pending=0
  trap 'pending=1' USR1
  _am_paint
  while true; do
    while [[ "$pending" == "1" ]]; do
      pending=0
      _am_paint
    done
    # Bounded wait, not indefinite: a SIGUSR1 landing between the drain check
    # and `wait` starting sets pending but doesn't interrupt the wait; the 1s
    # cap re-drains it. A received signal still interrupts immediately.
    sleep 1 & local spid=$!
    wait "$spid" 2>/dev/null || true
    kill "$spid" 2>/dev/null || true
  done
}

main() {
  for dep in jq ridge; do
    if ! _have "$dep"; then echo "aerospace_mode: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "aerospace_mode: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT
  trigger_loop
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so
# the guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

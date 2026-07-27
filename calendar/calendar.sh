#!/usr/bin/env bash
# Ridge calendar plugin: a date item whose popup lists the next 24h of Apple
# Calendar meetings; the date item turns orange while a busy meeting is in
# progress. See README.md. Talks to ridge over $RIDGE_SOCKET via the `ridge` CLI. The
# clock (time) item lives in the sibling `clock` plugin.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATE_ID="calendar.date"

_have() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC2034 # SETTING_* are consumed by main(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  # Icon font: the date item's calendar glyph (set via `ridge add --icon`) is
  # a Nerd Font glyph, so it renders as tofu in the system default font
  # unless a Nerd Font family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  SETTING_date_format="$(jq -r '.date_format // "%a %d/%m/%Y"' <<<"$json")"
  [[ -n "$SETTING_date_format" ]] || SETTING_date_format="%a %d/%m/%Y"
  # Poll interval in seconds. Must be a positive number, else default - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_date_interval="$(jq -r '.date_interval // "30"' <<<"$json")"
  [[ "$SETTING_date_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_date_interval//[.0]/}" ]] || SETTING_date_interval="30"
  SETTING_label_color="$(jq -r '.label_color // "theme:primary"' <<<"$json")"
  SETTING_icon_color="$(jq -r '.icon_color // "theme:system"' <<<"$json")"
  SETTING_date_icon="$(jq -r '.date_icon // "󰃭"' <<<"$json")"
  [[ -n "$SETTING_date_icon" ]] || SETTING_date_icon="󰃭"
  SETTING_bg_color="$(jq -r '.bg_color // "theme:background"' <<<"$json")"
  SETTING_busy_bg_color="$(jq -r '.busy_bg_color // "theme:warning"' <<<"$json")"
  SETTING_busy_fg_color="$(jq -r '.busy_fg_color // "#12161D"' <<<"$json")"
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
  SETTING_calendar_app="$(jq -r '.calendar_app // "BusyCal"' <<<"$json")"
  [[ -n "$SETTING_calendar_app" ]] || SETTING_calendar_app="BusyCal"
  SETTING_max_meetings="$(jq -r '.max_meetings // "8"' <<<"$json")"
  [[ "$SETTING_max_meetings" =~ ^[0-9]+$ && "$SETTING_max_meetings" -ge 1 && "$SETTING_max_meetings" -le 20 ]] || SETTING_max_meetings="8"
  SETTING_popup_header_color="$(jq -r '.popup_header_color // "theme:system"' <<<"$json")"
  SETTING_row_text_color="$(jq -r '.row_text_color // "theme:primary"' <<<"$json")"
  SETTING_row_icon_color="$(jq -r '.row_icon_color // "theme:secondary"' <<<"$json")"
  SETTING_in_progress_color="$(jq -r '.in_progress_color // "theme:success"' <<<"$json")"
}

# Pill geometry flags for the date item's `ridge add` call -
# extracted so bats can assert the flags without invoking the real `ridge`
# CLI. bg-color is passed separately at each call site since the date item's
# background alternates between bg_color and busy_bg_color.
_pill_flags() {
  local out=""
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- '--bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

# Sleeps until the next wall-clock boundary of `interval` seconds, so the
# refresh loop tracks real time instead of drifting by however long the
# preceding work (ridge set, _refresh_date) took. perl(1) ships on macOS by
# default; falls back to a plain `sleep "$interval"` if perl is unavailable.
_sleep_to_boundary() {
  local interval="$1"
  perl -MTime::HiRes=time,sleep -e '
    $i = shift; $i = 1 if $i <= 0;
    $t = time();
    $r = $i - ($t - int($t / $i) * $i);
    sleep($r > 0.001 ? $r : $i);
  ' "$interval" 2>/dev/null || sleep "$interval"
}

# Refreshes the date item's text, busy-state pill colors, and popup rows by
# querying calendar_meetings.py. Never lets a query failure crash the loop.
_refresh_date() {
  local out busy rows
  out="$(RIDGE_CAL_MAXROWS="$SETTING_max_meetings" RIDGE_CAL_APP="$SETTING_calendar_app" \
         RIDGE_CAL_HEADER_COLOR="$SETTING_popup_header_color" RIDGE_CAL_ROW_TEXT="$SETTING_row_text_color" \
         RIDGE_CAL_ROW_ICON="$SETTING_row_icon_color" RIDGE_CAL_INPROGRESS="$SETTING_in_progress_color" \
         python3 "${PLUGIN_ROOT}/calendar_meetings.py" 2>/dev/null)"
  [[ -n "$out" ]] || return 0

  busy="$(jq -r '.busy // false' <<<"$out" 2>/dev/null)"
  rows="$(jq -c '.rows // []' <<<"$out" 2>/dev/null)"

  if [[ "$busy" == "true" ]]; then
    ridge set "$DATE_ID" --bg-color "$SETTING_busy_bg_color" --icon-color "$SETTING_busy_fg_color" --color "$SETTING_busy_fg_color" 2>/dev/null || true
  else
    ridge set "$DATE_ID" --bg-color "$SETTING_bg_color" --icon-color "$SETTING_icon_color" --color "$SETTING_label_color" 2>/dev/null || true
  fi
  ridge set "$DATE_ID" --text "$(date +"$SETTING_date_format")" 2>/dev/null || true
  [[ -n "$rows" && "$rows" != "null" ]] && ridge popup set-rows "$DATE_ID" --json "$rows" 2>/dev/null || true
}

main() {
  for dep in jq python3 sqlite3 date ridge; do
    if ! _have "$dep"; then echo "calendar: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  load_settings

  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "calendar: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors/numbers only)
  ridge add "$DATE_ID" --region "$SETTING_region" --icon "$SETTING_date_icon" --text "$(date +"$SETTING_date_format")" \
    --icon-color "$SETTING_icon_color" --color "$SETTING_label_color" --font "$SETTING_font" \
    --bg-color "$SETTING_bg_color" --click "ridge popup toggle $DATE_ID" --icon-padding-right 10 $(_pill_flags) || true
  trap 'ridge remove "$DATE_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    _refresh_date

    # Aligns to the next wall-clock boundary instead of a fixed sleep, so
    # per-tick work (above) doesn't accumulate drift and skip seconds.
    _sleep_to_boundary "$SETTING_date_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so the
# guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

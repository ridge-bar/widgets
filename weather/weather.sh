#!/usr/bin/env bash
# Ridge weather plugin: condition glyph + temperature from wttr.in, plus a
# popup with current conditions and a 3-day forecast (see README.md). Talks
# to ridge over $RIDGE_SOCKET via the `ridge` CLI. Celsius only - see README
# "Units".
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEM_ID="weather.status"
# Fixed accent for the popup's title row.
# Not user-configurable - a fixed accent, not a threshold color (mirrors battery.sh).
WEATHER_TITLE_COLOR="#7DCFFF"

_have() { command -v "$1" >/dev/null 2>&1; }

sanitize() {
  local s="$1"
  printf '%s' "${s//[^A-Za-z0-9_-]/_}"
}

# shellcheck disable=SC2034 # SETTING_* are consumed by main(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  # Empty is the default and means "let wttr.in geo-IP the request", so the
  # widget works anywhere without configuration.
  SETTING_location="$(jq -r '.location // ""' <<<"$json")"
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  # Icon font: the weather condition glyph (set via `ridge set --icon`) is
  # a Nerd Font glyph, so it renders as tofu in the system default font
  # unless a Nerd Font family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  # Poll interval in seconds. Must be a positive number, else default 1800 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "1800"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="1800"
  SETTING_thunder_color="$(jq -r '.thunder_color // "theme:error"' <<<"$json")"
  SETTING_snow_color="$(jq -r '.snow_color // "theme:primary"' <<<"$json")"
  SETTING_sleet_color="$(jq -r '.sleet_color // "theme:system"' <<<"$json")"
  SETTING_rain_color="$(jq -r '.rain_color // "theme:system"' <<<"$json")"
  SETTING_fog_color="$(jq -r '.fog_color // "theme:secondary"' <<<"$json")"
  SETTING_overcast_color="$(jq -r '.overcast_color // "theme:secondary"' <<<"$json")"
  SETTING_cloud_color="$(jq -r '.cloud_color // "theme:secondary"' <<<"$json")"
  SETTING_sunny_color="$(jq -r '.sunny_color // "theme:warning"' <<<"$json")"
  SETTING_default_color="$(jq -r '.default_color // "theme:system"' <<<"$json")"
  SETTING_label_color="$(jq -r '.label_color // "theme:primary"' <<<"$json")"
  SETTING_bg_color="$(jq -r '.bg_color // "theme:background"' <<<"$json")"
  SETTING_rain_bg_color="$(jq -r '.rain_bg_color // "theme:system"' <<<"$json")"
  SETTING_storm_bg_color="$(jq -r '.storm_bg_color // "theme:error"' <<<"$json")"
  SETTING_highlight_text_color="$(jq -r '.highlight_text_color // "#12161D"' <<<"$json")"
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

# Condition description -> glyph + color. Prints "icon<TAB>color".
_weather_condition() {
  local desc="$1" icon col
  case "$desc" in
    *[Tt]hunder*)                           icon=$'\U000F0593'; col="$SETTING_thunder_color" ;;
    *[Ss]now* | *[Bb]lizzard*)              icon=$'\U000F0598'; col="$SETTING_snow_color" ;;
    *[Ss]leet* | *[Ii]ce*)                  icon=$'\U000F0598'; col="$SETTING_sleet_color" ;;
    *[Rr]ain* | *[Dd]rizzle* | *[Ss]hower*) icon=$'\U000F0597'; col="$SETTING_rain_color" ;;
    *[Ff]og* | *[Mm]ist* | *[Hh]aze*)       icon=$'\U000F0591'; col="$SETTING_fog_color" ;;
    *[Oo]vercast*)                          icon=$'\U000F0590'; col="$SETTING_overcast_color" ;;
    *[Cc]loud*)                             icon=$'\U000F0595'; col="$SETTING_cloud_color" ;;
    *[Ss]unny* | *[Cc]lear*)                icon=$'\U000F0599'; col="$SETTING_sunny_color" ;;
    *)                                      icon=$'\U000F0590'; col="$SETTING_default_color" ;;
  esac
  printf '%s\t%s' "$icon" "$col"
}

# near-severity -> background + icon/label colors. Wet weather (near current
# or within ~6h) highlights the background; icon+label go dark for contrast.
# Prints "bg<TAB>icon_color<TAB>label_color".
_weather_highlight() {
  local near="$1" cond_color="$2"
  case "$near" in
    storm) printf '%s\t%s\t%s' "$SETTING_storm_bg_color" "$SETTING_highlight_text_color" "$SETTING_highlight_text_color" ;;
    rain)  printf '%s\t%s\t%s' "$SETTING_rain_bg_color" "$SETTING_highlight_text_color" "$SETTING_highlight_text_color" ;;
    *)     printf '%s\t%s\t%s' "$SETTING_bg_color" "$cond_color" "$SETTING_label_color" ;;
  esac
}

# Cache path under $TMPDIR (falling back to /tmp), one file per location so a
# settings change never serves a stale reading for a different place.
_cache_file() {
  local key
  key="$(sanitize "$SETTING_location")"
  [[ -n "$key" ]] || key="auto"
  printf '%s/ridge_weather_%s.json' "${TMPDIR:-/tmp}" "$key"
}

# Refetches into $cache when missing or older than ~5/6 of the poll interval
# (a 25min-stale/30min-poll ratio at the default interval). Keeps the
# previous cached reading on a fetch failure instead of clobbering it.
_refresh_cache() {
  local cache="$1" stale_min tmp loc_encoded
  stale_min=$(( SETTING_interval * 5 / 6 / 60 ))
  [[ "$stale_min" -ge 1 ]] || stale_min=1
  if [[ -f "$cache" && -z "$(find "$cache" -mmin "+${stale_min}" 2>/dev/null)" ]]; then
    return 0
  fi
  loc_encoded="$(jq -rn --arg loc "$SETTING_location" '$loc|@uri')"
  tmp="${cache}.tmp.$$"
  if curl -fsS --max-time 12 "https://wttr.in/${loc_encoded}?format=j1" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$cache"
  else
    rm -f "$tmp"
  fi
}

# The popup's title row. An explicit setting wins; otherwise the area wttr.in
# geo-IP resolved is read back from the cached response, so the row names a
# place rather than showing blank.
_location_label() {
  local cache="$1" resolved
  if [[ -n "$SETTING_location" ]]; then
    printf '%s' "$SETTING_location"
    return 0
  fi
  resolved="$(jq -r '.nearest_area[0].areaName[0].value // empty' "$cache" 2>/dev/null)"
  printf '%s' "${resolved:-Current location}"
}

# Popup rows JSON from weather_popup_render.py's `row|icon|label` lines, safely
# via jq (never hand-spliced into the JSON string). A title row (location) is
# prepended.
_weather_popup_rows_json() {
  local render_output="$1" location="$2"
  jq -n \
    --arg title_color "$WEATHER_TITLE_COLOR" \
    --arg location "$location" \
    --arg rendered "$render_output" \
    '($rendered | split("\n") | map(select(length > 0))
       | map(try capture("^(?<id>[^|]*)\\|(?<cap>[^|]*)\\|(?<val>.*)$") catch null)
       | map(select(. != null))
       | map({icon: .cap, text: .val})) as $rows
     | [{icon: "Weather", text: $location, color: $title_color, icon_color: $title_color}] + $rows'
}

# Pill background flags for the item's `ridge add` call -
# extracted so bats can assert the flags without invoking the real `ridge`
# CLI. bg_color seeds the pill before the first successful fetch; the poll
# loop's own --bg-color (rain/storm highlight) overrides the color only -
# corner-radius/height/padding, set once here, persist across those calls.
_pill_flags() {
  local out
  out="$(printf -- '--bg-color %s' "$SETTING_bg_color")"
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- ' --bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  out+="$(printf -- ' --icon-padding-right %s' 10)"
  printf '%s' "$out"
}

main() {
  for dep in jq curl python3 ridge; do
    if ! _have "$dep"; then echo "weather: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "weather: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # Seed the item WITH an icon part (`--icon " "`): the poll loop's `ridge set`
  # updates `--icon`, which errors ("item has no icon") unless the item was
  # created with one - so a missing seed icon left the widget stuck at "--".
  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors/numbers only)
  ridge add "$ITEM_ID" --region "$SETTING_region" --icon " " --text "--" --font "$SETTING_font" --click "ridge popup toggle $ITEM_ID" $(_pill_flags) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    local cache; cache="$(_cache_file)"
    _refresh_cache "$cache"

    if [[ -s "$cache" ]]; then
      local temp desc near
      IFS=$'\t' read -r temp desc near < <(python3 "${PLUGIN_ROOT}/weather_parse.py" <"$cache")
      if [[ -n "$desc" ]]; then
        local icon cond_color
        IFS=$'\t' read -r icon cond_color < <(_weather_condition "$desc")
        local bg icon_color label_color
        IFS=$'\t' read -r bg icon_color label_color < <(_weather_highlight "$near" "$cond_color")
        ridge set "$ITEM_ID" --icon "$icon" --icon-color "$icon_color" --text "$temp" --color "$label_color" --bg-color "$bg" 2>/dev/null || true

        local rendered rows_json
        rendered="$(python3 "${PLUGIN_ROOT}/weather_popup_render.py" <"$cache")"
        rows_json="$(_weather_popup_rows_json "$rendered" "$(_location_label "$cache")")"
        ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
      fi
    fi

    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so the
# guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

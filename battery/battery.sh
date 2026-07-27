#!/usr/bin/env bash
# Ridge battery plugin: a charge-level glyph with threshold color, plus a
# details popup (charge status, time remaining, power source, health, cycles,
# temperature). See README.md. Talks to ridge over $RIDGE_SOCKET via the `ridge` CLI.
set -uo pipefail

ITEM_ID="battery.status"
# Tokyo Night green accent for the popup's title row.
# Not user-configurable - it is a fixed accent, not a threshold color.
BATTERY_TITLE_COLOR="#9ECE6A"

_have() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC2034 # SETTING_* are consumed by main(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  # Poll interval in seconds. Must be a positive number, else default 120 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "120"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="120"
  # Placement default only - ridge.yaml's plugins[].region and
  # plugins[].items override it. Not a user setting.
  SETTING_region="right"
  # Icon font: the battery charge glyph (set via `ridge set --icon` in the
  # poll loop) is a Nerd Font glyph, so it renders as tofu in the system
  # default font unless a Nerd Font family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  SETTING_warn_threshold="$(jq -r '.warn_threshold // "20"' <<<"$json")"
  [[ "$SETTING_warn_threshold" =~ ^[0-9]+$ && "$SETTING_warn_threshold" -ge 1 && "$SETTING_warn_threshold" -le 100 ]] || SETTING_warn_threshold="20"
  SETTING_crit_threshold="$(jq -r '.crit_threshold // "10"' <<<"$json")"
  [[ "$SETTING_crit_threshold" =~ ^[0-9]+$ && "$SETTING_crit_threshold" -ge 1 && "$SETTING_crit_threshold" -le 100 ]] || SETTING_crit_threshold="10"
  SETTING_warn_color="$(jq -r '.warn_color // "theme:warning"' <<<"$json")"
  SETTING_crit_color="$(jq -r '.crit_color // "theme:error"' <<<"$json")"
  SETTING_normal_color="$(jq -r '.normal_color // "theme:primary"' <<<"$json")"
  # Pill background, matching aerospace's workspace bubbles.
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

# Battery percent (0-100) from `pmset -g batt` output; empty if not found.
_battery_pct() {
  local pmset_out="$1"
  printf '%s\n' "$pmset_out" | grep -Eo '[0-9]+%' | head -1 | tr -d '%'
}

# "1" when on AC power (drives the charging-glyph override), else "0".
_battery_on_ac() {
  local pmset_out="$1"
  if printf '%s\n' "$pmset_out" | grep -q 'AC Power'; then printf '1'; else printf '0'; fi
}

# Charge status word: discharging|charging|charged|finishing charge; "-" if absent.
_battery_status() {
  local pmset_out="$1" s
  s="$(printf '%s' "$pmset_out" | grep -Eo 'discharging|charging|charged|finishing charge' | head -1)"
  printf '%s' "${s:--}"
}

# Time remaining, e.g. "3:42"; "-" when pmset has no estimate yet.
_battery_time_left() {
  local pmset_out="$1" t
  t="$(printf '%s' "$pmset_out" | grep -Eo '[0-9]+:[0-9]+ remaining' | sed 's/ remaining//')"
  printf '%s' "${t:--}"
}

# "AC Power" or "Battery", for the popup's power-source row.
_battery_power_source() {
  local pmset_out="$1"
  if printf '%s' "$pmset_out" | grep -q 'AC Power'; then printf 'AC Power'; else printf 'Battery'; fi
}

# Extracts a numeric ioreg field, e.g. `"CycleCount" = 342` -> "342".
_ioreg_val() {
  local ioreg_out="$1" key="$2"
  printf '%s' "$ioreg_out" | grep -Eo "\"${key}\" = [0-9]+" | grep -Eo '[0-9]+' | head -1
}

_battery_cycles() {
  local ioreg_out="$1" c
  c="$(_ioreg_val "$ioreg_out" CycleCount)"
  printf '%s' "${c:--}"
}

# Health = AppleRawMaxCapacity / DesignCapacity, rounded to a percent; "-" if
# DesignCapacity is missing or zero.
_battery_health() {
  local ioreg_out="$1" maxcap design
  maxcap="$(_ioreg_val "$ioreg_out" AppleRawMaxCapacity)"
  design="$(_ioreg_val "$ioreg_out" DesignCapacity)"
  awk -v m="${maxcap:-0}" -v d="${design:-0}" 'BEGIN { if (d > 0) printf "%d%%", m/d*100 + 0.5; else printf "-" }'
}

# Temperature in Celsius (ioreg reports centi-degrees); "-" if missing or zero.
_battery_temp() {
  local ioreg_out="$1" tc
  tc="$(_ioreg_val "$ioreg_out" Temperature)"
  awk -v t="${tc:-0}" 'BEGIN { if (t > 0) printf "%.1fC", t/100; else printf "-" }'
}

# Charge-level glyph: 90-100/60-89/30-59/10-29/<10 ladder; on_ac == "1" always
# overrides to the plug glyph, regardless of percent.
_battery_glyph() {
  local pct="$1" on_ac="$2" glyph
  case "$pct" in
    9[0-9] | 100) glyph="󰁹" ;;
    [6-8][0-9]) glyph="󰂀" ;;
    [3-5][0-9]) glyph="󰁾" ;;
    [1-2][0-9]) glyph="󰁻" ;;
    *) glyph="󰂃" ;;
  esac
  [[ "$on_ac" == "1" ]] && glyph="󰂄"
  printf '%s' "$glyph"
}

# Threshold color: below crit_threshold -> crit_color, below warn_threshold ->
# warn_color, else normal_color.
_battery_color() {
  local pct="$1" warn_threshold="$2" crit_threshold="$3" warn_color="$4" crit_color="$5" normal_color="$6"
  if [[ "$pct" -lt "$crit_threshold" ]]; then
    printf '%s' "$crit_color"
  elif [[ "$pct" -lt "$warn_threshold" ]]; then
    printf '%s' "$warn_color"
  else
    printf '%s' "$normal_color"
  fi
}

# Builds the 7-row popup JSON via `jq -n --arg` (not string splicing), so a
# battery/health value can never break the JSON payload.
_battery_popup_rows_json() {
  local pct="$1" status="$2" tleft="$3" power_source="$4" health="$5" cycles="$6" temp="$7"
  jq -n \
    --arg title_color "$BATTERY_TITLE_COLOR" \
    --arg charge_text "${pct}% (${status})" \
    --arg tleft "$tleft" \
    --arg power_source "$power_source" \
    --arg health "$health" \
    --arg cycles "$cycles" \
    --arg temp "$temp" \
    '[
      {icon: "Battery", text: "", color: $title_color, icon_color: $title_color},
      {icon: "Charge", text: $charge_text},
      {icon: "Time left", text: $tleft},
      {icon: "Power", text: $power_source},
      {icon: "Health", text: $health},
      {icon: "Cycles", text: $cycles},
      {icon: "Temp", text: $temp}
    ]'
}

# Pill background flags for the item's `ridge add` call -
# extracted so bats can assert the flags without invoking the real `ridge`
# CLI. Set once at add time: later `ridge set` calls only touch icon/color,
# and an item's background/padding persists across those (ridge only
# rewrites style.background when a bg/padding flag is present in that
# specific request).
_pill_flags() {
  local out
  out="$(printf -- '--bg-color %s' "$SETTING_bg_color")"
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- ' --bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

main() {
  for dep in jq pmset ioreg ridge; do
    if ! _have "$dep"; then echo "battery: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "battery: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors/numbers only)
  # Seed an icon part (`--icon " "`): the poll loop shows the battery glyph via
  # `ridge set --icon`, which errors ("item has no icon") unless the item was
  # created with one - so a missing seed icon left the glyph blank.
  ridge add "$ITEM_ID" --region "$SETTING_region" --icon " " --text "" --font "$SETTING_font" --click "ridge popup toggle $ITEM_ID" $(_pill_flags) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    local pmset_out pct
    pmset_out="$(pmset -g batt 2>/dev/null)"
    pct="$(_battery_pct "$pmset_out")"
    if [[ -n "$pct" ]]; then
      local on_ac glyph color
      on_ac="$(_battery_on_ac "$pmset_out")"
      glyph="$(_battery_glyph "$pct" "$on_ac")"
      color="$(_battery_color "$pct" "$SETTING_warn_threshold" "$SETTING_crit_threshold" "$SETTING_warn_color" "$SETTING_crit_color" "$SETTING_normal_color")"
      ridge set "$ITEM_ID" --icon "$glyph" --color "$color" 2>/dev/null || true

      local ioreg_out status tleft power_source health cycles temp rows_json
      ioreg_out="$(ioreg -rn AppleSmartBattery 2>/dev/null)"
      status="$(_battery_status "$pmset_out")"
      tleft="$(_battery_time_left "$pmset_out")"
      power_source="$(_battery_power_source "$pmset_out")"
      health="$(_battery_health "$ioreg_out")"
      cycles="$(_battery_cycles "$ioreg_out")"
      temp="$(_battery_temp "$ioreg_out")"
      rows_json="$(_battery_popup_rows_json "$pct" "$status" "$tleft" "$power_source" "$health" "$cycles" "$temp")"
      ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
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

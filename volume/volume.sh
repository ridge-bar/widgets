#!/usr/bin/env bash
# Ridge volume plugin: output/input audio volume glyph, backed by AppleScript
# "volume settings" with an optional BetterDisplay DDC fallback for displays
# whose volume macOS can't read/write in software, plus a popup for mute, a
# volume slider, and output/input device switching.
#
# Two implementation notes:
#  - The "notch width" branch (only show the 3-level glyph on the notched
#    built-in display, else always the high glyph) was a cosmetic hack tied
#    to physical bar width on a notch; dropped entirely. The 3-level icon
#    ladder is always used here.
#  - Sliders are backed by ridge's `slider` popup-row type: one draggable
#    output-volume slider and one draggable input-volume slider, replacing
#    the old 25/50/75/100% preset rows (and the +/-5% step rows - redundant
#    with the slider).
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEM_ID="volume.status"
BD_BIN="/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

_have() { command -v "$1" >/dev/null 2>&1; }

# `timeout` isn't shipped on macOS by default; alarm+exec is the standard
# shim (matches tasks.sh). Wraps every
# osascript/SwitchAudioSource/BetterDisplay call so a hung/slow external tool
# can never stall the poll loop or a click handler.
_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this script's
# own eval; device names are hostile input and must survive both layers.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# shellcheck disable=SC2034 # SETTING_* consumed by main()/paint helpers, not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  # Placement default only - ridge.yaml's plugins[].region and
  # plugins[].items override it. Not a user setting.
  SETTING_region="right"
  # Icon font: the volume-level icons (low/mid/high/muted) are Nerd Font
  # glyphs, so they render as tofu in the system default font unless a
  # Nerd Font family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"

  # Poll interval in seconds. Must be a positive number, else default 5 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "5"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="5"

  SETTING_icon_color="$(jq -r '.icon_color // "theme:primary"' <<<"$json")"
  SETTING_bg_color="$(jq -r '.bg_color // "theme:background"' <<<"$json")"
  SETTING_muted_color="$(jq -r '.muted_color // "theme:error"' <<<"$json")"
  SETTING_low_icon="$(jq -r '.low_icon // "󰕿"' <<<"$json")"
  SETTING_mid_icon="$(jq -r '.mid_icon // "󰖀"' <<<"$json")"
  SETTING_high_icon="$(jq -r '.high_icon // "󰕾"' <<<"$json")"
  SETTING_muted_icon="$(jq -r '.muted_icon // "󰖁"' <<<"$json")"
  SETTING_device_active_color="$(jq -r '.device_active_color // "theme:success"' <<<"$json")"

  SETTING_betterdisplay_enabled="$(jq -r '.betterdisplay_enabled // "false"' <<<"$json")"
  [[ "$SETTING_betterdisplay_enabled" == "true" || "$SETTING_betterdisplay_enabled" == "false" ]] || SETTING_betterdisplay_enabled="false"
  SETTING_betterdisplay_name="$(jq -r '.betterdisplay_name // ""' <<<"$json")"

  # Pill geometry, matching the other widgets' pills.
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

# "--bg-height N" only when the user explicitly set bg_height; empty
# otherwise so the item's `ridge add` call omits the flag and the pill
# height auto-adapts to the bar height (TASK-139).
_bg_height_flag() {
  [[ -n "$SETTING_bg_height" ]] && printf -- '--bg-height %s' "$SETTING_bg_height"
  return 0
}

# "--bg-corner-radius N" only when the user explicitly set corner_radius;
# empty otherwise so the item's `ridge add` call omits the flag and ridge
# core's global bar.item_corner_radius default applies.
_corner_radius_flag() {
  [[ -n "$SETTING_corner_radius" ]] && printf -- '--bg-corner-radius %s' "$SETTING_corner_radius"
  return 0
}

##############################################################################
# Pure functions: parsing, thresholds, clamping. No file I/O, no shelling
# out - directly testable against fixtures.
##############################################################################

# Parses the "VOL|MUTED" string produced by the osascript volume-settings
# query into "PCT<TAB>MUTED(0/1)". PCT is empty when VOL isn't a plain
# non-negative integer (osascript failure, timeout, "missing value").
_volume_parse_osascript() {
  local raw="$1" vol muted
  vol="${raw%%|*}"
  muted="${raw#*|}"
  if [[ "$vol" =~ ^[0-9]+$ ]]; then
    if [[ "$muted" == "true" ]]; then muted=1; else muted=0; fi
    printf '%s\t%s' "$vol" "$muted"
  else
    printf '\t0'
  fi
}

# Parses BetterDisplay's `get -mute -volume` comma-separated token output
# (e.g. "on,0.750000" or "off,0.250000") into "PCT<TAB>MUTED(0/1)". PCT is
# the fractional-volume token times 100, rounded to an integer; empty when no
# numeric fraction token is present.
_volume_parse_betterdisplay() {
  local out="$1" tok muted=0 vol=""
  local old_ifs="$IFS"
  IFS=,
  for tok in $out; do
    case "$tok" in
      on) muted=1 ;;
      off) muted=0 ;;
      *) vol="$tok" ;;
    esac
  done
  IFS="$old_ifs"
  if [[ -n "$vol" ]]; then
    local pct
    if pct="$(awk -v v="$vol" 'BEGIN { if (v == "" || v + 0 < 0) exit 1; printf "%d", v * 100 + 0.5 }')"; then
      printf '%s\t%s' "$pct" "$muted"
    else
      printf '\t%s' "$muted"
    fi
  else
    printf '\t%s' "$muted"
  fi
}

# Clamps to 0-100; non-numeric input heals to 0.
_volume_clamp_pct() {
  local v="$1"
  [[ "$v" =~ ^-?[0-9]+$ ]] || { printf '0'; return; }
  if (( v < 0 )); then v=0; fi
  if (( v > 100 )); then v=100; fi
  printf '%d' "$v"
}

# Icon ladder: muted or 0% -> muted_icon; else <=33% low, <=66% mid, else high.
_volume_icon() {
  local pct="$1" muted="$2" low="$3" mid="$4" high="$5" muted_icon="$6"
  if [[ "$muted" == "1" || "$pct" -eq 0 ]]; then
    printf '%s' "$muted_icon"
  elif [[ "$pct" -le 33 ]]; then
    printf '%s' "$low"
  elif [[ "$pct" -le 66 ]]; then
    printf '%s' "$mid"
  else
    printf '%s' "$high"
  fi
}

# Color: muted or 0% -> muted_color; else icon_color.
_volume_color() {
  local muted="$1" pct="$2" icon_color="$3" muted_color="$4"
  if [[ "$muted" == "1" || "$pct" -eq 0 ]]; then
    printf '%s' "$muted_color"
  else
    printf '%s' "$icon_color"
  fi
}

# "Mute" when unmuted (the row's action), "Unmute" when muted.
_volume_mute_label() {
  local muted="$1"
  if [[ "$muted" == "1" ]]; then printf 'Unmute'; else printf 'Mute'; fi
}

##############################################################################
# Runtime state I/O: thin file-backed wrappers, one file per key under
# $XDG_STATE_HOME/ridge/volume/ (same convention mindfulness introduced).
# Persists the last-known volume+mute reading (so the icon never goes blank
# on a hung audio stack), the current output device type (internal/external,
# so click handlers know whether to target osascript or BetterDisplay), and
# the emulated input-mute bookkeeping (see _handle_input_mute_toggle).
##############################################################################

_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/volume"
  mkdir -p "$dir" && chmod 0700 "$dir"
  printf '%s' "$dir"
}

_state_read() {
  local key="$1" default="$2" dir file
  dir="$(_state_dir)"
  file="${dir}/${key}"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    printf '%s' "$default"
  fi
}

# Atomic: write to a temp file then mv into place, so the poll loop never
# reads a torn/half-written value while a click handler is persisting one.
_state_write() {
  local key="$1" value="$2" dir tmp
  dir="$(_state_dir)"
  tmp="${dir}/.${key}.tmp.$$"
  printf '%s' "$value" > "$tmp" && mv -f "$tmp" "${dir}/${key}"
}

##############################################################################
# Live reads: osascript first, BetterDisplay DDC fallback, then last-known
# state. Prints "PCT<TAB>MUTED<TAB>SOURCE(internal|external|cache|none)".
##############################################################################

_read_volume() {
  local res parsed pct="" muted="0" source=""

  res="$(_timeout 1 osascript -e 'set s to (get volume settings)
return (output volume of s as string) & "|" & (output muted of s as string)' 2>/dev/null)"
  parsed="$(_volume_parse_osascript "$res")"
  # Split on the literal tab, not `read`: tab is IFS whitespace, so `read`
  # collapses a leading empty pct field and shifts muted into pct - turning a
  # failed/empty read into a spurious 0. See volume-zero-percent-investigation.
  pct="${parsed%%$'\t'*}"; muted="${parsed#*$'\t'}"

  if [[ -n "$pct" ]]; then
    source="internal"
  elif [[ "$SETTING_betterdisplay_enabled" == "true" && -n "$SETTING_betterdisplay_name" ]]; then
    local bd_out
    bd_out="$(_timeout 2 "$BD_BIN" get -namelike="$SETTING_betterdisplay_name" -mute -volume 2>/dev/null)"
    parsed="$(_volume_parse_betterdisplay "$bd_out")"
    pct="${parsed%%$'\t'*}"; muted="${parsed#*$'\t'}"
    [[ -n "$pct" ]] && source="external"
  fi

  if [[ -z "$pct" ]]; then
    local cached
    cached="$(_state_read last_volume_mute "")"
    if [[ -n "$cached" ]]; then
      read -r pct muted <<<"$cached"
      source="cache"
    fi
  fi

  printf '%s\t%s\t%s' "$pct" "${muted:-0}" "${source:-none}"
}

##############################################################################
# Click handlers: entry points for the self-reinvoke env vars below. Each
# performs one bounded action, then main() repaints via _tick.
##############################################################################

# Reads the actual current mute state fresh (not from stale popup data) and
# flips it.
_handle_mute_toggle() {
  local cur
  cur="$(_timeout 1 osascript -e 'output muted of (get volume settings)' 2>/dev/null)"
  if [[ "$cur" == "true" ]]; then
    _timeout 1 osascript -e 'set volume output muted false' >/dev/null 2>&1
  else
    _timeout 1 osascript -e 'set volume output muted true' >/dev/null 2>&1
  fi
}

# Sets output volume to an absolute percent. Targets osascript's software
# mixer normally; when the last successful read came from BetterDisplay (the
# device_type state flag), targets the DDC fractional volume instead.
_handle_set_output() {
  local pct device_type
  pct="$(_volume_clamp_pct "$1")"
  device_type="$(_state_read device_type "internal")"
  if [[ "$device_type" == "external" && "$SETTING_betterdisplay_enabled" == "true" && -n "$SETTING_betterdisplay_name" ]]; then
    local frac
    frac="$(awk -v p="$pct" 'BEGIN { printf "%.3f", p / 100 }')"
    _timeout 2 "$BD_BIN" set -namelike="$SETTING_betterdisplay_name" -volume="$frac" >/dev/null 2>&1
  else
    _timeout 1 osascript -e "set volume output volume $pct" >/dev/null 2>&1
  fi
}

_handle_set_input() {
  local pct
  pct="$(_volume_clamp_pct "$1")"
  _timeout 1 osascript -e "set volume input volume $pct" >/dev/null 2>&1
  _state_write input_muted "0"
}

# macOS's "volume settings" has no "input muted" property (only output
# volume, input volume, alert volume, output muted - confirmed against
# `osascript -e 'get volume settings'`'s record fields). There is nothing to
# read for input mute, so it's emulated: muting persists the current input
# volume then sets input volume to 0; unmuting restores the persisted value.
# This is a real limitation, not an oversight - documented in README.md.
_handle_input_mute_toggle() {
  local cur_muted
  cur_muted="$(_state_read input_muted "0")"
  if [[ "$cur_muted" == "1" ]]; then
    local restore
    restore="$(_state_read input_volume_before_mute "50")"
    _timeout 1 osascript -e "set volume input volume $restore" >/dev/null 2>&1
    _state_write input_muted "0"
  else
    local cur_vol
    cur_vol="$(_timeout 1 osascript -e 'input volume of (get volume settings)' 2>/dev/null)"
    [[ "$cur_vol" =~ ^[0-9]+$ ]] || cur_vol=50
    _state_write input_volume_before_mute "$cur_vol"
    _timeout 1 osascript -e 'set volume input volume 0' >/dev/null 2>&1
    _state_write input_muted "1"
  fi
}

_handle_switch_device() {
  local dev_type="$1" name="$2"
  [[ "$dev_type" == "input" || "$dev_type" == "output" ]] || dev_type="output"
  _timeout 2 SwitchAudioSource -s "$name" -t "$dev_type" >/dev/null 2>&1
}

##############################################################################
# Popup rows, built fresh every poll tick (and after every click handler) via
# `jq -n --arg`/collect-then-`jq -s`, never string splicing - device names
# are hostile input (see _volume_device_rows_json).
##############################################################################

# Builds a self-reinvoke click command: re-exec this script with the given
# env var assignment(s) set (plus RIDGE_PLUGIN_SETTINGS forwarded via shq).
# One builder, reused for every entry point in main() below.
build_reexec_cmd() {
  local env_assignment="$1" script_path="$2" settings_path="${3:-}"
  local out="$env_assignment"
  if [[ -n "$settings_path" ]]; then
    out="RIDGE_PLUGIN_SETTINGS=$(shq "$settings_path") ${out}"
  fi
  printf '%s %s' "$out" "$(shq "$script_path")"
}

# One row per detected device of the given type, up to 6, active device
# highlighted via device_active_color. Empty
# array when SwitchAudioSource isn't on PATH (soft dependency, no error).
# Device names are hostile input: text goes through jq --arg, never string
# interpolation; the click's device-name env var is shq-quoted so it can
# never break out of the exec command ridge core runs it through.
_volume_device_rows_json() {
  local dev_type="$1"
  _have SwitchAudioSource || { printf '[]'; return; }

  local current script_path="${PLUGIN_ROOT}/volume.sh" settings_path="${RIDGE_PLUGIN_SETTINGS:-}"
  current="$(_timeout 2 SwitchAudioSource -c -t "$dev_type" 2>/dev/null)"

  local -a items=()
  local dev click count=0
  while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    (( count >= 6 )) && break
    click="$(build_reexec_cmd "VOLUME_SWITCH_DEVICE_TYPE=${dev_type} VOLUME_SWITCH_DEVICE_NAME=$(shq "$dev")" "$script_path" "$settings_path")"
    if [[ "$dev" == "$current" ]]; then
      items+=("$(jq -n --arg text "$dev" --arg click "$click" --arg color "$SETTING_device_active_color" '{text: $text, click: $click, color: $color, close_on_click: false}')")
    else
      items+=("$(jq -n --arg text "$dev" --arg click "$click" '{text: $text, click: $click, close_on_click: false}')")
    fi
    (( count++ ))
  done < <(_timeout 2 SwitchAudioSource -a -t "$dev_type" 2>/dev/null)

  if [[ "${#items[@]}" -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${items[@]}" | jq -s '.'
  fi
}

# Full popup rows: Output header/mute/slider/devices, then the same
# for Input. out_muted drives the output mute row's label; out_pct seeds the
# output slider's initial thumb position (caller's already-read current
# volume - see _tick). The input mute row reads its own state directly (see
# _handle_input_mute_toggle).
#
# Each slider's `submit` is built via build_reexec_cmd with the *literal*
# text '$RIDGE_SLIDER' (single-quoted at the call site so this script's own
# bash never expands it): build_reexec_cmd splices its env_assignment arg
# into the output unquoted/unescaped, so that token survives verbatim into
# the JSON `submit` string. Ridge core runs `submit` via `/bin/sh -c` with
# RIDGE_SLIDER set to the new value at slider-change time (throttled,
# ~120ms), which is when the token actually expands - never at row-build
# time here, and never via string interpolation of the value itself.
_volume_popup_rows_json() {
  local out_muted="$1" out_pct
  out_pct="$(_volume_clamp_pct "${2:-}")"
  local script_path="${PLUGIN_ROOT}/volume.sh" settings_path="${RIDGE_PLUGIN_SETTINGS:-}"

  local mute_label mute_click output_slider_submit
  mute_label="$(_volume_mute_label "$out_muted")"
  mute_click="$(build_reexec_cmd "VOLUME_MUTE_TOGGLE=1" "$script_path" "$settings_path")"
  # shellcheck disable=SC2016 # $RIDGE_SLIDER must stay unexpanded here; ridge core expands it via /bin/sh -c at slider-change time
  output_slider_submit="$(build_reexec_cmd 'VOLUME_SET=$RIDGE_SLIDER' "$script_path" "$settings_path")"

  local header_rows_json
  header_rows_json="$(jq -n \
    --arg mute_label "$mute_label" --arg mute_click "$mute_click" \
    --arg submit "$output_slider_submit" --argjson value "$out_pct" \
    '[
      {type: "header", text: "Output"},
      {text: $mute_label, click: $mute_click, close_on_click: false},
      {type: "slider", min: 0, max: 100, value: $value, step: 1, submit: $submit}
    ]')"

  local output_device_rows_json
  output_device_rows_json="$(_volume_device_rows_json output)"

  local input_muted input_mute_label input_mute_click input_slider_submit
  input_muted="$(_state_read input_muted "0")"
  input_mute_label="$(_volume_mute_label "$input_muted")"
  input_mute_click="$(build_reexec_cmd "VOLUME_MUTE_INPUT_TOGGLE=1" "$script_path" "$settings_path")"
  # shellcheck disable=SC2016 # $RIDGE_SLIDER must stay unexpanded here; ridge core expands it via /bin/sh -c at slider-change time
  input_slider_submit="$(build_reexec_cmd 'VOLUME_SET_INPUT=$RIDGE_SLIDER' "$script_path" "$settings_path")"

  # No _read_volume-style fallback chain exists for input (osascript is the
  # only source ridge already uses for it - see _handle_input_mute_toggle).
  # A failed/non-numeric read falls back to the value the mute handler last
  # persisted, then 0; this seeds the slider's initial thumb position only,
  # same as out_pct above.
  local input_pct_raw input_pct
  input_pct_raw="$(_timeout 1 osascript -e 'input volume of (get volume settings)' 2>/dev/null)"
  if [[ "$input_pct_raw" =~ ^[0-9]+$ ]]; then
    input_pct="$(_volume_clamp_pct "$input_pct_raw")"
  else
    input_pct="$(_volume_clamp_pct "$(_state_read input_volume_before_mute "0")")"
  fi

  local input_header_rows_json
  input_header_rows_json="$(jq -n \
    --arg mute_label "$input_mute_label" --arg mute_click "$input_mute_click" \
    --arg submit "$input_slider_submit" --argjson value "$input_pct" \
    '[
      {type: "header", text: "Input"},
      {text: $mute_label, click: $mute_click, close_on_click: false},
      {type: "slider", min: 0, max: 100, value: $value, step: 1, submit: $submit}
    ]')"

  local input_device_rows_json
  input_device_rows_json="$(_volume_device_rows_json input)"

  jq -n \
    --argjson header "$header_rows_json" \
    --argjson outdev "$output_device_rows_json" \
    --argjson inhdr "$input_header_rows_json" \
    --argjson indev "$input_device_rows_json" \
    '$header + $outdev + $inhdr + $indev'
}

##############################################################################
# Paint: one poll tick. Reads live volume (with fallbacks), persists state,
# repaints the item glyph/label, and rebuilds the popup rows.
##############################################################################

_tick() {
  local read_out pct muted source

  read_out="$(_read_volume)"
  IFS=$'\t' read -r pct muted source <<<"$read_out"

  if [[ -z "$pct" ]]; then
    # No live reading and no cached last-known value: show a blank-state
    # icon (reusing low_icon) rather than a stale or blank label.
    ridge set "$ITEM_ID" --icon "$SETTING_low_icon" --color "$SETTING_icon_color" --text "" 2>/dev/null || true
    return
  fi

  _state_write last_volume_mute "${pct} ${muted}"
  [[ "$source" == "internal" || "$source" == "external" ]] && _state_write device_type "$source"

  local icon color
  icon="$(_volume_icon "$pct" "$muted" "$SETTING_low_icon" "$SETTING_mid_icon" "$SETTING_high_icon" "$SETTING_muted_icon")"
  color="$(_volume_color "$muted" "$pct" "$SETTING_icon_color" "$SETTING_muted_color")"
  ridge set "$ITEM_ID" --icon "$icon" --color "$color" --text "${pct}%" 2>/dev/null || true

  local rows_json
  rows_json="$(_volume_popup_rows_json "$muted" "$pct")"
  ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
}

main() {
  for dep in jq ridge; do
    if ! _have "$dep"; then echo "volume: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  load_settings

  # Self-reinvoke entry points, checked before the RIDGE_SOCKET guard (the
  # repaint inside _tick uses best-effort `ridge ... || true` calls, same as
  # amphetamine's toggle_and_paint).
  if [[ -n "${VOLUME_MUTE_TOGGLE:-}" ]]; then
    _handle_mute_toggle
    _tick
    exit 0
  fi
  if [[ -n "${VOLUME_SET:-}" ]]; then
    _handle_set_output "$VOLUME_SET"
    _tick
    exit 0
  fi
  if [[ -n "${VOLUME_SET_INPUT:-}" ]]; then
    _handle_set_input "$VOLUME_SET_INPUT"
    _tick
    exit 0
  fi
  if [[ -n "${VOLUME_MUTE_INPUT_TOGGLE:-}" ]]; then
    _handle_input_mute_toggle
    _tick
    exit 0
  fi
  if [[ -n "${VOLUME_SWITCH_DEVICE_TYPE:-}" && -n "${VOLUME_SWITCH_DEVICE_NAME:-}" ]]; then
    _handle_switch_device "$VOLUME_SWITCH_DEVICE_TYPE" "$VOLUME_SWITCH_DEVICE_NAME"
    _tick
    exit 0
  fi

  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "volume: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi

  # shellcheck disable=SC2046 # _corner_radius_flag/_bg_height_flag each emit a single --flag value pair with no embedded whitespace, or nothing
  ridge add "$ITEM_ID" --region "$SETTING_region" --text "" --icon "$SETTING_low_icon" --color "$SETTING_icon_color" --bg-color "$SETTING_bg_color" --click "ridge popup toggle $ITEM_ID" --font "$SETTING_font" --icon-padding-right 8 $(_corner_radius_flag) $(_bg_height_flag) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    _tick
    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so
# the guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

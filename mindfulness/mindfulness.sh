#!/usr/bin/env bash
# Ridge mindfulness plugin: a leaf-glyph item that counts down to a reminder,
# then pulses red and rings a bell once until acknowledged (clicking the
# quote row dismisses it and restarts the countdown). Left-click is
# contextual (enable/disable/show_reminder depending on phase); right-click
# opens a settings popup with interval/volume sliders. See README.md for the
# settings-vs-state split.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEM_ID="mindfulness.status"

# Leaf glyph (Nerd Font U+F06C).
MINDFULNESS_ICON=$'\uf06c'

# Leaf emoji (U+1F343), for popup rows only. Popups render icons in the
# system default font, which lacks the Nerd Font glyph above (renders as
# tofu); this codepoint falls back to Apple Color Emoji instead.
MINDFULNESS_POPUP_ICON=$'\U0001F343'

# Reminder messages shown on acknowledge.
reminders=(
  "Sit up straight -- stack your head over your hips."
  "Drop your shoulders away from your ears."
  "Unclench your jaw and soften your face."
  "Uncross your legs; plant both feet on the floor."
  "Pull your chin back -- stop craning toward the screen."
  "Slow breath in for 4, out for 6."
  "Three deep breaths. Make the exhale longer than the inhale."
  "Notice your breath for a moment without changing it."
  "Look 20 feet away for 20 seconds -- rest your eyes."
  "Blink slowly a few times; your eyes are dry."
  "Roll your shoulders back and down a few times."
  "Stand up and stretch -- your spine wants to move."
  "Relax your grip on the mouse; loosen your hands."
  "Take a sip of water."
  "Name one thing you can see, hear, and feel right now."
  "Where is your attention? Gently bring it back."
  "Unclench. You're allowed to slow down."
  "This moment is enough. Notice it."
)

_have() { command -v "$1" >/dev/null 2>&1; }

# True only when ridge core reports this item's popup as open right now
# (TASK-148). Any failure - non-zero exit, empty output, garbage output from
# an older core binary without `query popup` - reads as NOT visible, so the
# overdue click degrades to always showing a fresh quote instead of ever
# silently acknowledging (the TASK-145 bug this replaces).
_popup_visible() {
  local out
  out="$(ridge query popup "$ITEM_ID" 2>/dev/null)"
  [[ "$out" == "open" ]]
}

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this script's
# own eval; the click's script path and settings path must survive both.
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
  # Icon font: MINDFULNESS_ICON is a Nerd Font glyph, so it renders as tofu in
  # the system default font unless a Nerd Font family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"

  # Poll intervals feed `sleep` directly - a zero-equivalent value would spin
  # the loop. Same zero-equivalent guard as amphetamine/battery.
  SETTING_poll_counting="$(jq -r '.poll_counting // "10"' <<<"$json")"
  [[ "$SETTING_poll_counting" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_poll_counting//[.0]/}" ]] || SETTING_poll_counting="10"
  SETTING_poll_pulse="$(jq -r '.poll_pulse // "1"' <<<"$json")"
  [[ "$SETTING_poll_pulse" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_poll_pulse//[.0]/}" ]] || SETTING_poll_pulse="1"
  SETTING_poll_disabled="$(jq -r '.poll_disabled // "30"' <<<"$json")"
  [[ "$SETTING_poll_disabled" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_poll_disabled//[.0]/}" ]] || SETTING_poll_disabled="30"

  SETTING_default_interval="$(jq -r '.default_interval // "15"' <<<"$json")"
  [[ "$SETTING_default_interval" =~ ^[0-9]+$ && "$SETTING_default_interval" -ge 1 && "$SETTING_default_interval" -le 60 ]] || SETTING_default_interval="15"
  SETTING_default_volume="$(jq -r '.default_volume // "100"' <<<"$json")"
  [[ "$SETTING_default_volume" =~ ^[0-9]+$ && "$SETTING_default_volume" -ge 0 && "$SETTING_default_volume" -le 100 ]] || SETTING_default_volume="100"

  SETTING_enabled_color="$(jq -r '.enabled_color // "theme:success"' <<<"$json")"
  SETTING_disabled_color="$(jq -r '.disabled_color // "theme:warning"' <<<"$json")"
  SETTING_pulse_color="$(jq -r '.pulse_color // "theme:error"' <<<"$json")"
  SETTING_icon_color="$(jq -r '.icon_color // "#12161D"' <<<"$json")"
  SETTING_bell_sound="$(jq -r '.bell_sound // "/System/Library/Sounds/Submarine.aiff"' <<<"$json")"
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

##############################################################################
# Pure state-machine functions: (state, now) -> result. No file I/O, no
# `date` calls - callers pass explicit values so these are directly testable.
##############################################################################

# disabled | counting | overdue
_mindfulness_phase() {
  local enabled="$1" cycle_start="$2" interval_min="$3" now="$4"
  if [[ "$enabled" != "1" ]]; then
    printf 'disabled'
    return
  fi
  if (( now - cycle_start >= interval_min * 60 )); then
    printf 'overdue'
  else
    printf 'counting'
  fi
}

# Remaining seconds until overdue, clamped at 0.
_mindfulness_remaining() {
  local cycle_start="$1" interval_min="$2" now="$3" rem
  rem=$(( interval_min * 60 - (now - cycle_start) ))
  if (( rem < 0 )); then rem=0; fi
  printf '%d' "$rem"
}

# "7m 12s"
_mindfulness_fmt_remaining() {
  local rem="$1"
  if (( rem < 0 )); then rem=0; fi
  printf '%dm %02ds' "$(( rem / 60 ))" "$(( rem % 60 ))"
}

# Pure pulse-frame alternation from wall-clock parity, rather than a
# stateful /tmp PULSE-flag toggle. "1" = red frame, "0" = normal frame.
_mindfulness_pulse_on() {
  local now="$1"
  printf '%d' "$(( now % 2 ))"
}

# enable | disable | show_reminder | settings | noop
#
# While overdue, a left click always maps to show_reminder here - this
# function is pure and has no core connection to check live popup state.
# The caller (_mindfulness_handle_click) queries core (TASK-148) before
# acting on show_reminder: a visible popup acknowledges instead (same path
# as the popup's own quote row - see _mindfulness_reminder_row_json and the
# MINDFULNESS_CLICK=ack handling), an invisible one shows a fresh quote.
_mindfulness_click_action() {
  local button="$1" phase="$2"
  case "$button" in
    left)
      case "$phase" in
        disabled) printf 'enable' ;;
        counting) printf 'disable' ;;
        overdue) printf 'show_reminder' ;;
        *) printf 'noop' ;;
      esac
      ;;
    right) printf 'settings' ;;
    *) printf 'noop' ;;
  esac
}

##############################################################################
# Runtime state I/O: thin file-backed wrappers around the pure functions
# above. One file per key under $XDG_STATE_HOME/ridge/mindfulness/ - a new
# convention for this codebase, see README.md.
##############################################################################

_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/mindfulness"
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
# reads a torn/half-written value while a click handler is persisting one
# (the same temp+mv convention the tasks/weather caches use).
_state_write() {
  local key="$1" value="$2" dir tmp
  dir="$(_state_dir)"
  tmp="${dir}/.${key}.tmp.$$"
  printf '%s' "$value" > "$tmp" && mv -f "$tmp" "${dir}/${key}"
}

# "1" or "0"; anything else heals to "0" (the seeded default, not a setting).
_state_read_enabled() {
  local v
  v="$(_state_read enabled "0")"
  case "$v" in
    1 | 0) printf '%s' "$v" ;;
    *) printf '0' ;;
  esac
}

# Integer 1-60; anything else falls back to $1 (caller passes SETTING_default_interval).
_state_read_interval() {
  local default="$1" v
  v="$(_state_read interval_min "$default")"
  if [[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 && "$v" -le 60 ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$default"
  fi
}

# Integer 0-100; anything else falls back to $1 (caller passes SETTING_default_volume).
_state_read_volume() {
  local default="$1" v
  v="$(_state_read volume "$default")"
  if [[ "$v" =~ ^[0-9]+$ && "$v" -ge 0 && "$v" -le 100 ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$default"
  fi
}

# Positive integer; a missing/garbage value heals to now and is persisted so
# the healed value is stable across this process's subsequent reads.
_state_read_cycle_start() {
  local v now
  v="$(_state_read cycle_start "")"
  if [[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]]; then
    printf '%s' "$v"
  else
    now="$(date +%s)"
    _state_write cycle_start "$now"
    printf '%s' "$now"
  fi
}

# Ring the bell once at the configured volume; no-op when muted or the sound
# file is missing. Backgrounded so it never blocks the poll loop.
play_bell() {
  local vol frac
  vol="$(_state_read_volume "$SETTING_default_volume")"
  [[ "$vol" -le 0 ]] && return 0
  [[ -f "$SETTING_bell_sound" ]] || return 0
  frac="$(awk -v p="$vol" 'BEGIN { printf "%.3f", p / 100 }')"
  afplay -v "$frac" "$SETTING_bell_sound" >/dev/null 2>&1 &
}

# Builds a self-reinvoke click command: re-exec this script with the given
# env var assignment set (plus RIDGE_PLUGIN_SETTINGS forwarded via shq), so a
# row click mutates state and repaints without waiting for the next poll.
build_reexec_cmd() {
  local env_assignment="$1" script_path="$2" settings_path="${3:-}"
  local out="$env_assignment"
  if [[ -n "$settings_path" ]]; then
    out="RIDGE_PLUGIN_SETTINGS=$(shq "$settings_path") ${out}"
  fi
  printf '%s %s' "$out" "$(shq "$script_path")"
}

# Builds the settings popup rows via `jq -n --arg` (not string splicing):
# remaining time, On/Off toggle, then a draggable slider per group (interval,
# volume) - mirrors volume.sh's slider rows. The On/Off state is still marked
# with enabled_color; sliders show their own value, so they need no marker.
_mindfulness_settings_rows_json() {
  local remaining_text="$1" enabled="$2" interval_min="$3" volume="$4"
  local script_path="${PLUGIN_ROOT}/mindfulness.sh" settings_path="${RIDGE_PLUGIN_SETTINGS:-}"
  local eon eoff interval_submit volume_submit
  eon="$(build_reexec_cmd "MINDFULNESS_SET_ENABLED=1" "$script_path" "$settings_path")"
  eoff="$(build_reexec_cmd "MINDFULNESS_SET_ENABLED=0" "$script_path" "$settings_path")"
  # shellcheck disable=SC2016 # $RIDGE_SLIDER must stay unexpanded here; ridge core expands it via /bin/sh -c at slider-change time
  interval_submit="$(build_reexec_cmd 'MINDFULNESS_SET_INTERVAL=$RIDGE_SLIDER' "$script_path" "$settings_path")"
  # shellcheck disable=SC2016 # $RIDGE_SLIDER must stay unexpanded here; ridge core expands it via /bin/sh -c at slider-change time
  volume_submit="$(build_reexec_cmd 'MINDFULNESS_SET_VOLUME=$RIDGE_SLIDER' "$script_path" "$settings_path")"

  jq -n \
    --arg remaining "$remaining_text" \
    --argjson enabled "$enabled" \
    --argjson interval_min "$interval_min" \
    --argjson volume "$volume" \
    --arg sel_color "$SETTING_enabled_color" \
    --arg eon "$eon" --arg eoff "$eoff" \
    --arg interval_submit "$interval_submit" --arg volume_submit "$volume_submit" \
    '
    def preset_row(lbl; want; current; click):
      {text: lbl, click: click, close_on_click: false}
      + (if want == current then {color: $sel_color} else {} end);
    [
      {icon: "", text: $remaining},
      preset_row("On"; 1; $enabled; $eon),
      preset_row("Off"; 0; $enabled; $eoff),
      {text: "Interval"},
      {type: "slider", min: 1, max: 60, value: $interval_min, step: 1, submit: $interval_submit},
      {text: "Volume"},
      {type: "slider", min: 0, max: 100, value: $volume, step: 1, submit: $volume_submit}
    ]'
}

# Single-row popup shown while overdue. The row itself carries the
# acknowledge action - clicking it re-execs this script with
# MINDFULNESS_CLICK=ack, which hides the popup and restarts the countdown
# (_mindfulness_handle_click). No close_on_click override: a row with a
# click command defaults to closing on click, which is what we want here.
_mindfulness_reminder_row_json() {
  local message="$1"
  local script_path="${PLUGIN_ROOT}/mindfulness.sh" settings_path="${RIDGE_PLUGIN_SETTINGS:-}"
  local ack_click
  ack_click="$(build_reexec_cmd "MINDFULNESS_CLICK=ack" "$script_path" "$settings_path")"
  jq -n --arg icon "$MINDFULNESS_POPUP_ICON" --arg text "$message" --arg click "$ack_click" \
    '[{icon: $icon, text: $text, click: $click}]'
}

# Pill background flags (corner-radius/height/padding) for
# the item's `ridge add` call - extracted so bats can assert the flags
# without invoking the real `ridge` CLI. Only corner-radius/height/padding
# here, not bg-color: mindfulness's own enabled/disabled/pulse colors already
# serve as the pill color, applied separately by each _paint_* function.
_pill_flags() {
  local out=""
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- '--bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

_paint_disabled() {
  ridge set "$ITEM_ID" --icon "$MINDFULNESS_ICON" --icon-color "$SETTING_icon_color" --bg-color "$SETTING_disabled_color" 2>/dev/null || true
}

_paint_counting() {
  ridge set "$ITEM_ID" --icon "$MINDFULNESS_ICON" --icon-color "$SETTING_icon_color" --bg-color "$SETTING_enabled_color" 2>/dev/null || true
}

# One pulse frame: background alternates enabled_color/pulse_color while
# overdue; the glyph itself always stays icon_color so it reads on both frames.
_paint_pulse() {
  local pulse_on="$1" bg
  if [[ "$pulse_on" == "1" ]]; then bg="$SETTING_pulse_color"; else bg="$SETTING_enabled_color"; fi
  ridge set "$ITEM_ID" --icon "$MINDFULNESS_ICON" --icon-color "$SETTING_icon_color" --bg-color "$bg" 2>/dev/null || true
}

# Rebuilds and pushes the settings popup rows for the current state.
_refresh_settings_popup() {
  local now enabled cycle_start interval_min volume phase remaining remaining_text rows_json
  now="$(date +%s)"
  enabled="$(_state_read_enabled)"
  cycle_start="$(_state_read_cycle_start)"
  interval_min="$(_state_read_interval "$SETTING_default_interval")"
  volume="$(_state_read_volume "$SETTING_default_volume")"
  phase="$(_mindfulness_phase "$enabled" "$cycle_start" "$interval_min" "$now")"
  case "$phase" in
    disabled) remaining_text="Disabled" ;;
    overdue) remaining_text="Overdue" ;;
    *)
      remaining="$(_mindfulness_remaining "$cycle_start" "$interval_min" "$now")"
      remaining_text="$(_mindfulness_fmt_remaining "$remaining") left"
      ;;
  esac
  rows_json="$(_mindfulness_settings_rows_json "$remaining_text" "$enabled" "$interval_min" "$volume")"
  ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
}

# Entry point for MINDFULNESS_CLICK=<left|right|ack>. left/right compute the
# phase-driven action and apply it; ack is the quote row's own click
# (_mindfulness_reminder_row_json), routed directly since it doesn't depend
# on phase. Repaints immediately instead of waiting for the next poll.
#
# While overdue, a left click asks core whether the popup is visible right
# now (_popup_visible, TASK-148) rather than mirroring visibility in plugin
# state - that mirroring was the root cause of TASK-145's swallowed-quotes
# bug. Visible: acknowledge (hide + restart the timer), same as the quote
# row's own click. Not visible (including when core can't be asked, e.g. an
# older core binary): show a fresh random quote.
_mindfulness_handle_click() {
  local button="$1"
  if [[ "$button" == "ack" ]]; then
    ridge popup hide "$ITEM_ID" 2>/dev/null || true
    # Widget may have been disabled while the quote popup was still open;
    # re-check enabled so an ack doesn't resurrect the counting paint or
    # restart a cycle that shouldn't be running.
    if [[ "$(_state_read_enabled)" == "1" ]]; then
      _state_write cycle_start "$(date +%s)"
      _paint_counting
    else
      _paint_disabled
    fi
    return
  fi

  local now enabled cycle_start interval_min phase action
  now="$(date +%s)"
  enabled="$(_state_read_enabled)"
  cycle_start="$(_state_read_cycle_start)"
  interval_min="$(_state_read_interval "$SETTING_default_interval")"
  phase="$(_mindfulness_phase "$enabled" "$cycle_start" "$interval_min" "$now")"
  action="$(_mindfulness_click_action "$button" "$phase")"

  case "$action" in
    enable)
      _state_write enabled 1
      _state_write cycle_start "$now"
      _paint_counting
      ;;
    disable)
      _state_write enabled 0
      _paint_disabled
      ;;
    show_reminder)
      # A visible popup means the user is looking at a quote already - a
      # second leaf click acknowledges it (same path as clicking the quote
      # row itself) instead of silently swapping in a new one. When core
      # can't confirm visibility (see _popup_visible), degrade to showing.
      if _popup_visible; then
        _mindfulness_handle_click ack
      else
        local msg rows_json
        msg="${reminders[$((RANDOM % ${#reminders[@]}))]}"
        rows_json="$(_mindfulness_reminder_row_json "$msg")"
        ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
        ridge popup show "$ITEM_ID" 2>/dev/null || true
      fi
      ;;
    settings)
      _refresh_settings_popup
      ridge popup toggle "$ITEM_ID" 2>/dev/null || true
      ;;
    noop) : ;;
  esac
}

# Entry point for MINDFULNESS_SET_ENABLED=<0|1>: the settings-popup On/Off
# row click - the discoverable way to stop/start the countdown (previously
# only a left-click while counting could disable it). Enabling resets
# cycle_start to now, matching the `enable` action in
# _mindfulness_handle_click, so the countdown starts fresh. Repaints the item
# immediately, unlike set_interval/set_volume, since this changes the item's
# phase; always refreshes the settings popup so its On/Off markers stay in
# sync.
_mindfulness_handle_set_enabled() {
  local val="$1"
  case "$val" in
    1)
      _state_write enabled 1
      _state_write cycle_start "$(date +%s)"
      _paint_counting
      ;;
    0)
      _state_write enabled 0
      _paint_disabled
      ;;
  esac
  _refresh_settings_popup
}

# Entry point for MINDFULNESS_SET_INTERVAL=<minutes>: the settings-popup
# interval slider's submit. Rejects out-of-range values (defensive; the
# slider is clamped to 1-60) and always repushes the rows so the slider's
# thumb position stays in sync.
_mindfulness_handle_set_interval() {
  local val="$1"
  if [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 && "$val" -le 60 ]]; then
    _state_write interval_min "$val"
  fi
  _refresh_settings_popup
}

# Entry point for MINDFULNESS_SET_VOLUME=<percent>: the settings-popup volume
# slider's submit, mirrors _mindfulness_handle_set_interval.
_mindfulness_handle_set_volume() {
  local val="$1"
  if [[ "$val" =~ ^[0-9]+$ && "$val" -ge 0 && "$val" -le 100 ]]; then
    _state_write volume "$val"
  fi
  _refresh_settings_popup
}

main() {
  for dep in jq ridge afplay; do
    if ! _have "$dep"; then echo "mindfulness: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  load_settings

  if [[ -n "${MINDFULNESS_CLICK:-}" ]]; then
    _mindfulness_handle_click "$MINDFULNESS_CLICK"
    exit 0
  fi
  if [[ -n "${MINDFULNESS_SET_ENABLED:-}" ]]; then
    _mindfulness_handle_set_enabled "$MINDFULNESS_SET_ENABLED"
    exit 0
  fi
  if [[ -n "${MINDFULNESS_SET_INTERVAL:-}" ]]; then
    _mindfulness_handle_set_interval "$MINDFULNESS_SET_INTERVAL"
    exit 0
  fi
  if [[ -n "${MINDFULNESS_SET_VOLUME:-}" ]]; then
    _mindfulness_handle_set_volume "$MINDFULNESS_SET_VOLUME"
    exit 0
  fi

  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "mindfulness: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi

  # First-run seed: only the keys that should survive process restarts.
  # cycle_start is deliberately NOT seeded here - it is reset unconditionally
  # below.
  local state_dir; state_dir="$(_state_dir)"
  [[ -f "${state_dir}/enabled" ]] || _state_write enabled 0
  [[ -f "${state_dir}/interval_min" ]] || _state_write interval_min "$SETTING_default_interval"
  [[ -f "${state_dir}/volume" ]] || _state_write volume "$SETTING_default_volume"
  _state_write cycle_start "$(date +%s)"

  local left_click_cmd right_click_cmd
  left_click_cmd="$(build_reexec_cmd "MINDFULNESS_CLICK=left" "${PLUGIN_ROOT}/mindfulness.sh" "${RIDGE_PLUGIN_SETTINGS:-}")"
  right_click_cmd="$(build_reexec_cmd "MINDFULNESS_CLICK=right" "${PLUGIN_ROOT}/mindfulness.sh" "${RIDGE_PLUGIN_SETTINGS:-}")"

  local enabled init_bg
  enabled="$(_state_read_enabled)"
  if [[ "$enabled" == "1" ]]; then init_bg="$SETTING_enabled_color"; else init_bg="$SETTING_disabled_color"; fi

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (numbers only)
  ridge add "$ITEM_ID" --region "$SETTING_region" --text "" --icon "$MINDFULNESS_ICON" --icon-color "$SETTING_icon_color" --bg-color "$init_bg" --click "$left_click_cmd" --right-click "$right_click_cmd" --font "$SETTING_font" $(_pill_flags) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  # The only in-memory state the loop holds: whether the bell has already
  # played for the current on-disk cycle_start, so it never re-plays every
  # tick while overdue.
  local last_belled_cycle_start=""
  while true; do
    local now cycle_start interval_min phase
    enabled="$(_state_read_enabled)"
    cycle_start="$(_state_read_cycle_start)"
    interval_min="$(_state_read_interval "$SETTING_default_interval")"
    now="$(date +%s)"
    phase="$(_mindfulness_phase "$enabled" "$cycle_start" "$interval_min" "$now")"
    case "$phase" in
      disabled)
        _paint_disabled
        sleep "$SETTING_poll_disabled"
        ;;
      counting)
        _paint_counting
        sleep "$SETTING_poll_counting"
        ;;
      overdue)
        if [[ "$cycle_start" != "$last_belled_cycle_start" ]]; then
          play_bell
          last_belled_cycle_start="$cycle_start"
        fi
        local pulse_on
        pulse_on="$(_mindfulness_pulse_on "$now")"
        _paint_pulse "$pulse_on"
        sleep "$SETTING_poll_pulse"
        ;;
    esac
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so
# the guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

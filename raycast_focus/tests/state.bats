#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/raycast_focus.sh"
}

@test "_raycast_count_to_state maps the AX on/off result to a state word" {
  local input expected
  # The AppleScript now decides on/off (an active session's countdown title
  # contains a colon); the parse just passes on/off through and maps anything
  # else to unknown.
  for pair in "on:on" "off:off" ":unknown" "abc:unknown" "2:unknown"; do
    input="${pair%%:*}"
    expected="${pair##*:}"
    run _raycast_count_to_state "$input"
    [ "$output" = "$expected" ] || { echo "input=$input expected=$expected got=$output"; false; }
  done
}

@test "paint_state sets the on color when a session is running" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  RIDGE_SET_ARGS_FILE="$(mktemp)"
  ridge() { printf '%s\n' "$*" > "$RIDGE_SET_ARGS_FILE"; }
  focus_state() { printf on; }
  paint_state
  run cat "$RIDGE_SET_ARGS_FILE"
  [[ "$output" == *"set $ITEM_ID"* ]]
  [[ "$output" == *"--bg-color $SETTING_on_color"* ]]
  rm -f "$RIDGE_SET_ARGS_FILE"
}

@test "paint_state sets the off color when no session is running" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  RIDGE_SET_ARGS_FILE="$(mktemp)"
  ridge() { printf '%s\n' "$*" > "$RIDGE_SET_ARGS_FILE"; }
  focus_state() { printf off; }
  paint_state
  run cat "$RIDGE_SET_ARGS_FILE"
  [[ "$output" == *"set $ITEM_ID"* ]]
  [[ "$output" == *"--bg-color $SETTING_off_color"* ]]
  rm -f "$RIDGE_SET_ARGS_FILE"
}

@test "paint_state leaves the color untouched when state is unknown" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  RIDGE_SET_ARGS_FILE="$(mktemp)"
  rm -f "$RIDGE_SET_ARGS_FILE"
  ridge() { printf '%s\n' "$*" > "$RIDGE_SET_ARGS_FILE"; }
  focus_state() { printf unknown; }
  paint_state
  [ ! -f "$RIDGE_SET_ARGS_FILE" ]
}

@test "build_click_cmd embeds RAYCAST_TOGGLE=1 and the script path" {
  run build_click_cmd "/some path/raycast_focus.sh" ""
  [[ "$output" == *"RAYCAST_TOGGLE=1"* ]]
  [[ "$output" == *"'/some path/raycast_focus.sh'"* ]]
}

@test "build_click_cmd forwards RIDGE_PLUGIN_SETTINGS when a settings file is given" {
  run build_click_cmd "/plugin/raycast_focus.sh" "/plugin/settings.json"
  [[ "$output" == *"RIDGE_PLUGIN_SETTINGS='/plugin/settings.json'"* ]]
  [[ "$output" == *"RAYCAST_TOGGLE=1"* ]]
}

@test "_raycast tracked state round-trips and defaults to off" {
  export XDG_STATE_HOME="$(mktemp -d)"
  [ "$(_raycast_read_tracked)" = "off" ]   # default, no file
  _raycast_write_tracked on
  [ "$(_raycast_read_tracked)" = "on" ]
  _raycast_write_tracked off
  [ "$(_raycast_read_tracked)" = "off" ]
  # no leftover temp file
  run bash -c 'ls "$XDG_STATE_HOME"/ridge/raycast_focus/.active.tmp.* 2>/dev/null'
  [ -z "$output" ]
  rm -rf "$XDG_STATE_HOME"; unset XDG_STATE_HOME
}

@test "toggle start then paint uses the on color even when AX reports off (TASK-121)" {
  export XDG_STATE_HOME="$(mktemp -d)"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  RIDGE_SET_ARGS_FILE="$(mktemp)"
  open() { :; }
  ridge() { printf '%s\n' "$*" >> "$RIDGE_SET_ARGS_FILE"; }
  _raycast_ax_count() { printf 'off'; return 0; }   # AX never confirms (icon-only Focus)
  _raycast_wait_for_flip() { return 0; }             # skip the poll delay
  # tracked starts off -> start toggle -> tracked on -> paint must use on_color
  toggle_and_paint
  run cat "$RIDGE_SET_ARGS_FILE"
  [[ "$output" == *"--bg-color $SETTING_on_color"* ]]
  rm -f "$RIDGE_SET_ARGS_FILE"; rm -rf "$XDG_STATE_HOME"; unset XDG_STATE_HOME
}

@test "toggle stop then paint uses the off color (TASK-121)" {
  export XDG_STATE_HOME="$(mktemp -d)"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  RIDGE_SET_ARGS_FILE="$(mktemp)"
  open() { :; }
  ridge() { printf '%s\n' "$*" >> "$RIDGE_SET_ARGS_FILE"; }
  _raycast_ax_count() { printf 'off'; return 0; }
  _raycast_wait_for_flip() { return 0; }
  _raycast_write_tracked on
  toggle_and_paint                                   # on -> off
  run cat "$RIDGE_SET_ARGS_FILE"
  [[ "$output" == *"--bg-color $SETTING_off_color"* ]]
  rm -f "$RIDGE_SET_ARGS_FILE"; rm -rf "$XDG_STATE_HOME"; unset XDG_STATE_HOME
}

@test "toggle flips tracked state and fires the matching deeplink" {
  export XDG_STATE_HOME="$(mktemp -d)"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  OPENED="$(mktemp)"
  open() { printf '%s\n' "$*" >> "$OPENED"; }
  ridge() { :; }
  _raycast_ax_count() { return 1; }       # AX down -> tracked drives it
  _raycast_wait_for_flip() { return 0; }   # skip the poll delay
  # start: tracked off -> on, start deeplink
  toggle_and_paint
  [ "$(_raycast_read_tracked)" = "on" ]
  grep -q 'raycast://focus/start' "$OPENED"
  : > "$OPENED"
  # stop: tracked on -> off, complete deeplink (this is the "second click stops")
  toggle_and_paint
  [ "$(_raycast_read_tracked)" = "off" ]
  grep -q 'raycast://focus/complete' "$OPENED"
  rm -f "$OPENED"; rm -rf "$XDG_STATE_HOME"; unset XDG_STATE_HOME
}

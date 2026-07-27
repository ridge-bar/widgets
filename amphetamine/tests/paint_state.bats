#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/amphetamine.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  RIDGE_SET_ARGS_FILE="$(mktemp)"
  # Stub the ridge CLI so paint_state's `ridge set ...` is captured instead
  # of hitting a real socket.
  ridge() { printf '%s\n' "$*" > "$RIDGE_SET_ARGS_FILE"; }
}

teardown() {
  rm -f "$RIDGE_SET_ARGS_FILE"
}

@test "paint_state sets the active glyph/colors when a session is running" {
  is_active() { return 0; }
  paint_state
  run cat "$RIDGE_SET_ARGS_FILE"
  [[ "$output" == *"set amphetamine.toggle"* ]]
  [[ "$output" == *"--text $AMPH_GLYPH_ACTIVE"* ]]
  [[ "$output" == *"--color $SETTING_glyph_color"* ]]
  [[ "$output" == *"--bg-color $SETTING_on_color"* ]]
}

@test "paint_state sets the inactive glyph/colors when no session is running" {
  is_active() { return 1; }
  paint_state
  run cat "$RIDGE_SET_ARGS_FILE"
  [[ "$output" == *"set amphetamine.toggle"* ]]
  [[ "$output" == *"--text $AMPH_GLYPH_INACTIVE"* ]]
  [[ "$output" == *"--color $SETTING_glyph_color"* ]]
  [[ "$output" == *"--bg-color $SETTING_off_color"* ]]
}

@test "paint_state honors overridden colors from settings" {
  local f; f="$(mktemp)"
  printf '%s' '{"on_color":"#111111","off_color":"#222222","glyph_color":"#333333"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"

  is_active() { return 0; }
  paint_state
  run cat "$RIDGE_SET_ARGS_FILE"
  [[ "$output" == *"--color #333333"* ]]
  [[ "$output" == *"--bg-color #111111"* ]]
}

@test "build_click_cmd embeds AMPHETAMINE_TOGGLE=1 and the script path" {
  run build_click_cmd "/some path/amphetamine.sh" ""
  [[ "$output" == *"AMPHETAMINE_TOGGLE=1"* ]]
  [[ "$output" == *"'/some path/amphetamine.sh'"* ]]
}

@test "build_click_cmd forwards RIDGE_PLUGIN_SETTINGS when a settings file is given" {
  run build_click_cmd "/plugin/amphetamine.sh" "/plugin/settings.json"
  [[ "$output" == *"RIDGE_PLUGIN_SETTINGS='/plugin/settings.json'"* ]]
  [[ "$output" == *"AMPHETAMINE_TOGGLE=1"* ]]
}

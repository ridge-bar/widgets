#!/usr/bin/env bats
# Exercises the pill corner-radius/height flags
# added to the item's `ridge add` call. bg-color is intentionally excluded
# here - on_color/off_color already serve as the pill color, set
# separately by paint_state.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/raycast_focus.sh"
}

@test "_pill_flags omits corner_radius/bg_height by default (unset -> ridge global default)" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  run _pill_flags
  [[ "$output" != *"--bg-corner-radius"* ]]
  [[ "$output" != *"--bg-height"* ]]
  [[ "$output" != *"--bg-color"* ]]
}

@test "_pill_flags honors overridden corner_radius/bg_height" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"10","bg_height":"30"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  run _pill_flags
  [[ "$output" == *"--bg-corner-radius 10"* ]]
  [[ "$output" == *"--bg-height 30"* ]]
}

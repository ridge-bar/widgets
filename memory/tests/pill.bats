#!/usr/bin/env bats
# Exercises the sketchybar-style pill background flags added to the item's
# `ridge add` call (bg-color/corner-radius/height).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/memory.sh"
}

@test "_pill_flags uses the default bg_color and omits corner-radius/bg-height (auto)" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  run _pill_flags
  [[ "$output" == *"--bg-color theme:background"* ]]
  [[ "$output" != *"--bg-corner-radius"* ]]
  [[ "$output" != *"--bg-height"* ]]
}

@test "_pill_flags honors overridden bg_color/corner_radius/bg_height" {
  local f; f="$(mktemp)"
  printf '%s' '{"bg_color":"#111111","corner_radius":"10","bg_height":"30"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  run _pill_flags
  [[ "$output" == *"--bg-color #111111"* ]]
  [[ "$output" == *"--bg-corner-radius 10"* ]]
  [[ "$output" == *"--bg-height 30"* ]]
}

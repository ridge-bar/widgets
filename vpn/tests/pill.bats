#!/usr/bin/env bats
# Exercises the pill flags added to the item's `ridge add`
# call (corner-radius/height - no bg-color, since bg tracks
# connection state via `ridge set` instead).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/vpn.sh"
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

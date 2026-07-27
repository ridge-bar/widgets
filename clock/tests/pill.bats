#!/usr/bin/env bats
# Exercises the pill geometry flags for the `ridge add` call
# (corner-radius/height), and statically checks the `ridge add` line
# in the script for item id and expected flags.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/clock.sh"
}

@test "_pill_flags omits corner_radius/bg-height by default (unset -> ridge global default)" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  run _pill_flags
  [[ "$output" != *"--bg-corner-radius"* ]]
  [[ "$output" != *"--bg-height"* ]]
}

@test "_pill_flags does not emit --bg-color (passed separately at each call site)" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  run _pill_flags
  [[ "$output" != *"--bg-color"* ]]
}

@test "_pill_flags honors overridden corner_radius/bg_height" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"10","bg_height":"30"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  run _pill_flags
  [[ "$output" == *"--bg-corner-radius 10"* ]]
  [[ "$output" == *"--bg-height 30"* ]]
}

@test "the clock.time ridge add line uses ITEM_ID, pill flags, no icon, and a click" {
  block="$(sed -n '/ridge add "\$ITEM_ID"/,/|| true/p' "${PLUGIN_DIR}/clock.sh")"
  [ -n "$block" ]
  [[ "$block" == *'"$ITEM_ID"'* ]]
  [[ "$block" == *'_pill_flags'* ]]
  [[ "$block" != *'--icon '* ]]
  [[ "$block" == *'--click'* ]]
}

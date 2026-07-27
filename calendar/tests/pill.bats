#!/usr/bin/env bats
# Exercises the sketchybar-style pill geometry flags for the date item's
# `ridge add` call (corner-radius/height), and statically checks that
# `ridge add` line for item id and expected flags.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/calendar.sh"
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

@test "the calendar.date ridge add line uses DATE_ID, icon, click-to-toggle-popup, and pill flags" {
  block="$(sed -n '/ridge add "\$DATE_ID"/,/|| true/p' "${PLUGIN_DIR}/calendar.sh")"
  [ -n "$block" ]
  [[ "$block" == *'"$DATE_ID"'* ]]
  [[ "$block" == *'--icon "$SETTING_date_icon"'* ]]
  [[ "$block" == *'--click "ridge popup toggle $DATE_ID"'* ]]
  [[ "$block" == *'--icon-padding-right 10'* ]]
  [[ "$block" == *'_pill_flags'* ]]
}

#!/usr/bin/env bats
# near-severity -> background-highlight picker: rain/storm highlight the
# background and force dark icon/label text; clear keeps the defaults.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/weather.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
}

@test "_weather_highlight storm uses storm_bg_color and dark text" {
  run _weather_highlight storm "#7DCFFF"
  [ "$output" = $'theme:error\t#12161D\t#12161D' ]
}

@test "_weather_highlight rain uses rain_bg_color and dark text" {
  run _weather_highlight rain "#7DCFFF"
  [ "$output" = $'theme:system\t#12161D\t#12161D' ]
}

@test "_weather_highlight clear keeps bg_color, condition color, and label_color" {
  run _weather_highlight clear "#7DCFFF"
  [ "$output" = $'theme:background\t#7DCFFF\ttheme:primary' ]
}

@test "_weather_highlight passes through the condition color unchanged on clear" {
  run _weather_highlight clear "#E0AF68"
  [ "$output" = $'theme:background\t#E0AF68\ttheme:primary' ]
}

@test "_weather_highlight honors overridden bg/highlight settings" {
  local f; f="$(mktemp)"
  printf '%s' '{"rain_bg_color":"#111111","highlight_text_color":"#222222"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  run _weather_highlight rain "#7DCFFF"
  [ "$output" = $'#111111\t#222222\t#222222' ]
  rm -f "$f"
}

#!/usr/bin/env bats
# Condition-description -> glyph/color picker, across every bucket.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/weather.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
}

@test "_weather_condition matches thunder" {
  run _weather_condition "Thundery outbreaks possible"
  [ "$status" -eq 0 ]
  [ "$output" = $'\U000F0593\ttheme:error' ]
}

@test "_weather_condition matches snow and blizzard" {
  run _weather_condition "Light snow"
  [ "$output" = $'\U000F0598\ttheme:primary' ]
  run _weather_condition "Blizzard"
  [ "$output" = $'\U000F0598\ttheme:primary' ]
}

@test "_weather_condition matches sleet and ice" {
  run _weather_condition "Sleet"
  [ "$output" = $'\U000F0598\ttheme:system' ]
  run _weather_condition "Ice pellets"
  [ "$output" = $'\U000F0598\ttheme:system' ]
}

@test "_weather_condition matches rain, drizzle, and shower" {
  run _weather_condition "Patchy rain possible"
  [ "$output" = $'\U000F0597\ttheme:system' ]
  run _weather_condition "Light drizzle"
  [ "$output" = $'\U000F0597\ttheme:system' ]
  run _weather_condition "Light shower"
  [ "$output" = $'\U000F0597\ttheme:system' ]
}

@test "_weather_condition matches fog, mist, and haze" {
  run _weather_condition "Fog"
  [ "$output" = $'\U000F0591\ttheme:secondary' ]
  run _weather_condition "Mist"
  [ "$output" = $'\U000F0591\ttheme:secondary' ]
  run _weather_condition "Haze"
  [ "$output" = $'\U000F0591\ttheme:secondary' ]
}

@test "_weather_condition matches overcast" {
  run _weather_condition "Overcast"
  [ "$output" = $'\U000F0590\ttheme:secondary' ]
}

@test "_weather_condition matches cloud" {
  run _weather_condition "Partly cloudy"
  [ "$output" = $'\U000F0595\ttheme:secondary' ]
}

@test "_weather_condition matches sunny and clear" {
  run _weather_condition "Sunny"
  [ "$output" = $'\U000F0599\ttheme:warning' ]
  run _weather_condition "Clear"
  [ "$output" = $'\U000F0599\ttheme:warning' ]
}

@test "_weather_condition falls back to the default bucket" {
  run _weather_condition "Unknown weather phenomenon"
  [ "$output" = $'\U000F0590\ttheme:system' ]
}

@test "_weather_condition uses overridden settings colors" {
  local f; f="$(mktemp)"
  printf '%s' '{"thunder_color":"#123456"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  run _weather_condition "Thunderstorm"
  [ "$output" = $'\U000F0593\t#123456' ]
  rm -f "$f"
}

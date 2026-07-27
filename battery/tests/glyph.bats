#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  # Sourcing must NOT start the poll loop.
  source "${PLUGIN_DIR}/battery.sh"
}

@test "_battery_glyph: 90-100 band" {
  run _battery_glyph 90 0
  [ "$output" = "󰁹" ]
  run _battery_glyph 100 0
  [ "$output" = "󰁹" ]
}

@test "_battery_glyph: 60-89 band" {
  run _battery_glyph 60 0
  [ "$output" = "󰂀" ]
  run _battery_glyph 89 0
  [ "$output" = "󰂀" ]
}

@test "_battery_glyph: 30-59 band" {
  run _battery_glyph 30 0
  [ "$output" = "󰁾" ]
  run _battery_glyph 59 0
  [ "$output" = "󰁾" ]
}

@test "_battery_glyph: 10-29 band" {
  run _battery_glyph 10 0
  [ "$output" = "󰁻" ]
  run _battery_glyph 29 0
  [ "$output" = "󰁻" ]
}

@test "_battery_glyph: below 10 falls to the lowest glyph" {
  run _battery_glyph 9 0
  [ "$output" = "󰂃" ]
  run _battery_glyph 0 0
  [ "$output" = "󰂃" ]
}

@test "_battery_glyph: charging overrides the band glyph regardless of percent" {
  run _battery_glyph 5 1
  [ "$output" = "󰂄" ]
  run _battery_glyph 50 1
  [ "$output" = "󰂄" ]
  run _battery_glyph 100 1
  [ "$output" = "󰂄" ]
}

@test "_battery_color: below crit_threshold is crit_color" {
  run _battery_color 5 20 10 "#WARN" "#CRIT" "#NORMAL"
  [ "$output" = "#CRIT" ]
  run _battery_color 9 20 10 "#WARN" "#CRIT" "#NORMAL"
  [ "$output" = "#CRIT" ]
}

@test "_battery_color: at or above crit_threshold but below warn_threshold is warn_color" {
  run _battery_color 10 20 10 "#WARN" "#CRIT" "#NORMAL"
  [ "$output" = "#WARN" ]
  run _battery_color 19 20 10 "#WARN" "#CRIT" "#NORMAL"
  [ "$output" = "#WARN" ]
}

@test "_battery_color: at or above warn_threshold is normal_color" {
  run _battery_color 20 20 10 "#WARN" "#CRIT" "#NORMAL"
  [ "$output" = "#NORMAL" ]
  run _battery_color 100 20 10 "#WARN" "#CRIT" "#NORMAL"
  [ "$output" = "#NORMAL" ]
}

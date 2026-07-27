#!/usr/bin/env bats
# _cpu_bar_char: idx = floor((pct*8+99)/100), clamped 1-8, mapped to the
# 8-level bar-block glyph ladder. Boundaries verified per band.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/cpu.sh"
}

@test "_cpu_bar_char: 0 clamps to the lowest glyph" {
  run _cpu_bar_char 0
  [ "$output" = "▁" ]
}

@test "_cpu_bar_char: band 1 (1-12)" {
  run _cpu_bar_char 1
  [ "$output" = "▁" ]
  run _cpu_bar_char 12
  [ "$output" = "▁" ]
}

@test "_cpu_bar_char: band 2 (13-25)" {
  run _cpu_bar_char 13
  [ "$output" = "▂" ]
  run _cpu_bar_char 25
  [ "$output" = "▂" ]
}

@test "_cpu_bar_char: band 3 (26-37)" {
  run _cpu_bar_char 26
  [ "$output" = "▃" ]
  run _cpu_bar_char 37
  [ "$output" = "▃" ]
}

@test "_cpu_bar_char: band 4 (38-50)" {
  run _cpu_bar_char 38
  [ "$output" = "▄" ]
  run _cpu_bar_char 50
  [ "$output" = "▄" ]
}

@test "_cpu_bar_char: band 5 (51-62)" {
  run _cpu_bar_char 51
  [ "$output" = "▅" ]
  run _cpu_bar_char 62
  [ "$output" = "▅" ]
}

@test "_cpu_bar_char: band 6 (63-75)" {
  run _cpu_bar_char 63
  [ "$output" = "▆" ]
  run _cpu_bar_char 75
  [ "$output" = "▆" ]
}

@test "_cpu_bar_char: band 7 (76-87)" {
  run _cpu_bar_char 76
  [ "$output" = "▇" ]
  run _cpu_bar_char 87
  [ "$output" = "▇" ]
}

@test "_cpu_bar_char: band 8 (88-100)" {
  run _cpu_bar_char 88
  [ "$output" = "█" ]
  run _cpu_bar_char 100
  [ "$output" = "█" ]
}

@test "_cpu_color: at or above crit_threshold is crit_color" {
  run _cpu_color 90 75 90 "#WARN" "#CRIT" "#HEALTHY"
  [ "$output" = "#CRIT" ]
  run _cpu_color 100 75 90 "#WARN" "#CRIT" "#HEALTHY"
  [ "$output" = "#CRIT" ]
}

@test "_cpu_color: at or above warn_threshold but below crit_threshold is warn_color" {
  run _cpu_color 75 75 90 "#WARN" "#CRIT" "#HEALTHY"
  [ "$output" = "#WARN" ]
  run _cpu_color 89 75 90 "#WARN" "#CRIT" "#HEALTHY"
  [ "$output" = "#WARN" ]
}

@test "_cpu_color: below warn_threshold is the healthy color" {
  run _cpu_color 0 75 90 "#WARN" "#CRIT" "#HEALTHY"
  [ "$output" = "#HEALTHY" ]
  run _cpu_color 74 75 90 "#WARN" "#CRIT" "#HEALTHY"
  [ "$output" = "#HEALTHY" ]
}

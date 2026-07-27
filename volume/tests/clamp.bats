#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/volume.sh"
}

@test "_volume_clamp_pct passes through in-range values" {
  run _volume_clamp_pct 42
  [ "$output" = "42" ]
}

@test "_volume_clamp_pct clamps below zero to zero" {
  run _volume_clamp_pct -5
  [ "$output" = "0" ]
  run _volume_clamp_pct -100
  [ "$output" = "0" ]
}

@test "_volume_clamp_pct clamps above 100 to 100" {
  run _volume_clamp_pct 150
  [ "$output" = "100" ]
}

@test "_volume_clamp_pct accepts the boundary values" {
  run _volume_clamp_pct 0
  [ "$output" = "0" ]
  run _volume_clamp_pct 100
  [ "$output" = "100" ]
}

@test "_volume_clamp_pct falls back to zero on non-numeric input" {
  run _volume_clamp_pct abc
  [ "$output" = "0" ]
  run _volume_clamp_pct ""
  [ "$output" = "0" ]
}

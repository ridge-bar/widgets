#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/mindfulness.sh"
  STATE_TMP="$(mktemp -d)"
  export XDG_STATE_HOME="$STATE_TMP"
}

teardown() {
  rm -rf "$STATE_TMP"
}

@test "_state_dir creates and returns \$XDG_STATE_HOME/ridge/mindfulness" {
  run _state_dir
  [ "$status" -eq 0 ]
  [ "$output" = "${STATE_TMP}/ridge/mindfulness" ]
  [ -d "$output" ]
}

@test "_state_write then _state_read round-trips a value" {
  _state_write mykey "hello"
  run _state_read mykey "fallback"
  [ "$output" = "hello" ]
}

@test "_state_read returns the default when the file does not exist" {
  run _state_read missingkey "fallback"
  [ "$output" = "fallback" ]
}

@test "_state_read_enabled accepts 1 and 0" {
  _state_write enabled 1
  run _state_read_enabled
  [ "$output" = "1" ]

  _state_write enabled 0
  run _state_read_enabled
  [ "$output" = "0" ]
}

@test "_state_read_enabled heals an invalid value to 0" {
  _state_write enabled "garbage"
  run _state_read_enabled
  [ "$output" = "0" ]
}

@test "_state_read_enabled defaults to 0 when unset" {
  run _state_read_enabled
  [ "$output" = "0" ]
}

@test "_state_read_interval accepts an in-range value" {
  _state_write interval_min 30
  run _state_read_interval 15
  [ "$output" = "30" ]
}

@test "_state_read_interval falls back to the default on an out-of-range or non-numeric value" {
  _state_write interval_min 0
  run _state_read_interval 15
  [ "$output" = "15" ]

  _state_write interval_min 61
  run _state_read_interval 15
  [ "$output" = "15" ]

  _state_write interval_min "abc"
  run _state_read_interval 15
  [ "$output" = "15" ]
}

@test "_state_read_volume accepts an in-range value including 0" {
  _state_write volume 0
  run _state_read_volume 100
  [ "$output" = "0" ]

  _state_write volume 100
  run _state_read_volume 50
  [ "$output" = "100" ]
}

@test "_state_read_volume falls back to the default on an out-of-range or non-numeric value" {
  _state_write volume 101
  run _state_read_volume 100
  [ "$output" = "100" ]

  _state_write volume "-5"
  run _state_read_volume 100
  [ "$output" = "100" ]
}

@test "_state_read_cycle_start returns a persisted valid value unchanged" {
  _state_write cycle_start 1234567890
  run _state_read_cycle_start
  [ "$output" = "1234567890" ]
}

@test "_state_read_cycle_start heals a missing value to now and persists it" {
  local before after
  before="$(date +%s)"
  run _state_read_cycle_start
  after="$(date +%s)"
  [ "$output" -ge "$before" ]
  [ "$output" -le "$after" ]

  # The healed value must be written back so the next read is stable.
  run _state_read cycle_start ""
  [ "$output" -ge "$before" ]
  [ "$output" -le "$after" ]
}

@test "_state_read_cycle_start heals a garbage or non-positive value" {
  _state_write cycle_start ""
  run _state_read_cycle_start
  [ "$output" -gt 0 ]

  _state_write cycle_start "0"
  run _state_read_cycle_start
  [ "$output" -gt 0 ]

  _state_write cycle_start "not-a-number"
  run _state_read_cycle_start
  [ "$output" -gt 0 ]
}

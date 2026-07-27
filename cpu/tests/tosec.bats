#!/usr/bin/env bats
# _cpu_tosec: parses a `ps cputime` field (H:MM:SS, MM:SS, or SS) into
# total seconds.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/cpu.sh"
}

@test "_cpu_tosec parses H:MM:SS" {
  run _cpu_tosec "1:02:03"
  [ "$output" = "3723" ]
}

@test "_cpu_tosec parses MM:SS" {
  run _cpu_tosec "5:30"
  [ "$output" = "330" ]
}

@test "_cpu_tosec parses bare SS" {
  run _cpu_tosec "45"
  [ "$output" = "45" ]
}

@test "_cpu_tosec parses a zero duration" {
  run _cpu_tosec "0:00"
  [ "$output" = "0" ]
}

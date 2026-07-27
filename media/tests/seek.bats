#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/media.sh"
}

@test "_media_seek_target adds a positive delta and clamps to duration" {
  run _media_seek_target 350 10 374
  [ "$status" -eq 0 ]
  [ "$output" = "360" ]
}

@test "_media_seek_target adds a negative delta and clamps to 0" {
  run _media_seek_target 5 -10 374
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "_media_seek_target clamps a forward seek past the end to duration" {
  run _media_seek_target 370 10 374
  [ "$status" -eq 0 ]
  [ "$output" = "374" ]
}

@test "_media_seek_target treats an empty elapsed as zero" {
  run _media_seek_target "" 10 374
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

@test "_media_seek_target truncates fractional seconds to an integer" {
  run _media_seek_target 128.531 10 374
  [ "$status" -eq 0 ]
  [ "$output" = "138" ]
}

@test "_media_seek_target no-ops (empty output, failure status) when duration is empty" {
  run _media_seek_target 100 10 ""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_media_seek_target no-ops when duration is zero or negative" {
  run _media_seek_target 100 10 0
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run _media_seek_target 100 10 -5
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

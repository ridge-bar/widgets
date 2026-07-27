#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/media.sh"
}

@test "_media_format_time formats whole minutes and seconds" {
  run _media_format_time 128.531000
  [ "$output" = "2:08" ]
  run _media_format_time 374
  [ "$output" = "6:14" ]
  run _media_format_time 5
  [ "$output" = "0:05" ]
}

@test "_media_format_time falls back to 0:00 when empty" {
  run _media_format_time ""
  [ "$output" = "0:00" ]
}

@test "_media_format_time falls back to 0:00 when negative" {
  run _media_format_time -5
  [ "$output" = "0:00" ]
}

@test "_media_format_time formats zero as 0:00" {
  run _media_format_time 0
  [ "$output" = "0:00" ]
}

@test "_media_truncate_label passes text through unchanged when under the limit" {
  run _media_truncate_label "Daft Punk - Random Access Memories" 100
  [ "$output" = "Daft Punk - Random Access Memories" ]
}

@test "_media_truncate_label truncates and appends an ellipsis when over the limit" {
  run _media_truncate_label "Daft Punk - Random Access Memories" 10
  [ "$output" = "Daft Punk…" ]
  [ "${#output}" -eq 10 ]
}

@test "_media_truncate_label passes text through unchanged at exactly the limit" {
  run _media_truncate_label "12345" 5
  [ "$output" = "12345" ]
}

@test "_media_truncate_label handles a max_length of 1" {
  run _media_truncate_label "Hello" 1
  [ "$output" = "H" ]
}

#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/volume.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
}

@test "_volume_parse_osascript reads a normal unmuted reading" {
  run _volume_parse_osascript "$(cat "${FIX}/osascript_normal.txt")"
  [ "$output" = "$(printf '50\t0')" ]
}

@test "_volume_parse_osascript reads a muted reading" {
  run _volume_parse_osascript "$(cat "${FIX}/osascript_muted.txt")"
  [ "$output" = "$(printf '0\t1')" ]
}

@test "_volume_parse_osascript yields an empty pct on a failed/missing reading" {
  run _volume_parse_osascript "$(cat "${FIX}/osascript_fail.txt")"
  [ "$output" = "$(printf '\t0')" ]
}

@test "_volume_parse_osascript yields an empty pct on an empty string" {
  run _volume_parse_osascript ""
  [ "$output" = "$(printf '\t0')" ]
}

@test "_volume_parse_betterdisplay reads an unmuted fractional reading" {
  run _volume_parse_betterdisplay "$(cat "${FIX}/betterdisplay_unmuted.txt")"
  [ "$output" = "$(printf '75\t0')" ]
}

@test "_volume_parse_betterdisplay reads a muted fractional reading" {
  run _volume_parse_betterdisplay "$(cat "${FIX}/betterdisplay_muted.txt")"
  [ "$output" = "$(printf '25\t1')" ]
}

@test "_volume_parse_betterdisplay yields an empty pct when no fraction token is present" {
  run _volume_parse_betterdisplay "on"
  [ "$output" = "$(printf '\t1')" ]
}

@test "_volume_parse_betterdisplay yields an empty pct on an empty string" {
  run _volume_parse_betterdisplay ""
  [ "$output" = "$(printf '\t0')" ]
}

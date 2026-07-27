#!/usr/bin/env bats
# Pure-logic tests for _notif_cut and _notif_parse_count - no sqlite3, no
# filesystem, no clock dependency. Expected values below are computed
# independently (via `python3 -c`), not by re-deriving the same shell
# arithmetic expression the implementation uses.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/notifications.sh"
}

@test "_notif_cut: now_epoch=1000000000 -> 21433600" {
  run _notif_cut 1000000000
  [ "$output" = "21433600" ]
}

@test "_notif_cut: now_epoch=0 -> -978566400" {
  run _notif_cut 0
  [ "$output" = "-978566400" ]
}

@test "_notif_cut: now_epoch=978307200 (Core Data epoch itself) -> -259200" {
  run _notif_cut 978307200
  [ "$output" = "-259200" ]
}

@test "_notif_cut: now_epoch=1700000000 -> 721433600" {
  run _notif_cut 1700000000
  [ "$output" = "721433600" ]
}

@test "_notif_parse_count: clean numeric string with trailing newline" {
  result="$(_notif_parse_count "$(printf '3\n')")"
  [ "$result" = "3" ]
}

@test "_notif_parse_count: zero is a valid count" {
  result="$(_notif_parse_count "0")"
  [ "$result" = "0" ]
}

@test "_notif_parse_count: sqlite error text returns empty" {
  result="$(_notif_parse_count "Error: unable to open database file")"
  [ "$result" = "" ]
}

@test "_notif_parse_count: empty string returns empty" {
  result="$(_notif_parse_count "")"
  [ "$result" = "" ]
}

@test "_notif_parse_count: non-numeric garbage returns empty" {
  result="$(_notif_parse_count "abc")"
  [ "$result" = "" ]
}

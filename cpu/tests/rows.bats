#!/usr/bin/env bats
# Exercises _cpu_popup_rows_json (single-column top-CPU view), including the
# hostile-process-name safety property: a process name with shell/JSON
# metacharacters must never break the JSON output.
#
# Row 0 is the summary header; process rows follow from index 1.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/cpu.sh"
}

@test "empty lines produce just the header row" {
  run _cpu_popup_rows_json ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  [ "$(echo "$output" | jq 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.[0].type')" = "header" ]
  [[ "$(echo "$output" | jq -r '.[0].text')" == CPU* ]]
}

@test "processes are turned into icon/text rows" {
  local lines
  lines=$'12.3\tchrome\n5.0\tSafari'
  run _cpu_popup_rows_json "$lines"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  # summary header + 2 process rows = 3.
  [ "$(echo "$output" | jq 'length')" = "3" ]
  [ "$(echo "$output" | jq -r '.[1].icon')" = "12.3%" ]
  [ "$(echo "$output" | jq -r '.[1].text')" = "chrome" ]
  [ "$(echo "$output" | jq -r '.[2].icon')" = "5.0%" ]
  [ "$(echo "$output" | jq -r '.[2].text')" = "Safari" ]
}

@test "a hostile process name never breaks JSON parsing or escapes the cell" {
  local lines
  lines=$'12.3\tEvil"; rm -rf / # \x60touch pwned\x60 $(touch pwned)'
  run _cpu_popup_rows_json "$lines"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  local text
  text="$(echo "$output" | jq -r '.[1].text')"
  [[ "$text" == *"rm -rf"* ]]
  [ ! -e pwned ]
}

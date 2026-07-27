#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/clockify.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
}

@test "_clockify_popup_rows_json emits the 4 fixed rows plus one row per recent task" {
  run _clockify_popup_rows_json "Docs · Write report" 10 "Task A" "Task B"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 6'
  echo "$output" | jq -e '.[0].icon == "󰔛" and .[0].text == "Docs · Write report"'
  echo "$output" | jq -e '.[1].text == "Open Clockify Desktop"'
  echo "$output" | jq -e '.[2].text == "Open Calendar"'
  echo "$output" | jq -e '.[3].text == "Open Reports"'
  echo "$output" | jq -e '.[4].icon == "󰐊" and .[4].text == "Task A"'
  echo "$output" | jq -e '.[5].icon == "󰐊" and .[5].text == "Task B"'
}

@test "_clockify_popup_rows_json emits only the 4 fixed rows when there is no recent history" {
  run _clockify_popup_rows_json "Not tracking" 10
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 4'
}

@test "_clockify_popup_rows_json caps recent rows at max_rows even with more history available" {
  run _clockify_popup_rows_json "Not tracking" 2 "A" "B" "C" "D"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 6'
  echo "$output" | jq -e '.[4].text == "A" and .[5].text == "B"'
}

@test "_clockify_popup_rows_json wires a click on every row" {
  run _clockify_popup_rows_json "Current" 10 "Recent A"
  echo "$output" | jq -e 'length == 5'
  for i in 0 1 2 3 4; do
    echo "$output" | jq -e ".[$i] | has(\"click\") and (.click | length > 0)"
  done
}

@test "_clockify_popup_rows_json current row click re-execs CLOCKIFY_ACTION=stop" {
  run _clockify_popup_rows_json "Current" 10
  echo "$output" | jq -e '.[0].click | contains("CLOCKIFY_ACTION=stop")'
}

@test "_clockify_popup_rows_json open rows re-exec the matching CLOCKIFY_OPEN destination" {
  run _clockify_popup_rows_json "Current" 10
  echo "$output" | jq -e '.[1].click | contains("CLOCKIFY_OPEN=desktop")'
  echo "$output" | jq -e '.[2].click | contains("CLOCKIFY_OPEN=calendar")'
  echo "$output" | jq -e '.[3].click | contains("CLOCKIFY_OPEN=reports")'
}

@test "_clockify_popup_rows_json recent row click re-execs CLOCKIFY_START_INDEX at the 0-based position" {
  run _clockify_popup_rows_json "Current" 10 "First" "Second" "Third"
  echo "$output" | jq -e '.[4].click | contains("CLOCKIFY_START_INDEX=0")'
  echo "$output" | jq -e '.[5].click | contains("CLOCKIFY_START_INDEX=1")'
  echo "$output" | jq -e '.[6].click | contains("CLOCKIFY_START_INDEX=2")'
}

@test "_clockify_popup_rows_json safely escapes JSON-breaking characters in the current label" {
  run _clockify_popup_rows_json 'Task" ; rm -rf / - "Evil' 10
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 4'
  echo "$output" | jq -e '.[0].text | contains("rm -rf")'
}

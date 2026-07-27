#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/clockify.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
}

@test "_clockify_clean_token strips leading/trailing/embedded whitespace and newlines" {
  run _clockify_clean_token $'  abc123\n'
  [ "$output" = "abc123" ]

  run _clockify_clean_token $'ab\tc1\n23  '
  [ "$output" = "abc123" ]
}

@test "_clockify_clean_token on an empty/whitespace-only string yields empty" {
  run _clockify_clean_token $'   \n\t  '
  [ "$output" = "" ]
}

@test "_clockify_state_color: RUNNING uses tracking_color" {
  run _clockify_state_color "RUNNING" "#TRACK" "#IDLE"
  [ "$output" = "#TRACK" ]
}

@test "_clockify_state_color: IDLE uses idle_color" {
  run _clockify_state_color "IDLE" "#TRACK" "#IDLE"
  [ "$output" = "#IDLE" ]
}

@test "_clockify_state_color: any non-RUNNING value falls back to idle_color" {
  run _clockify_state_color "" "#TRACK" "#IDLE"
  [ "$output" = "#IDLE" ]
  run _clockify_state_color "garbage" "#TRACK" "#IDLE"
  [ "$output" = "#IDLE" ]
}

@test "_clockify_index_in_range accepts indices within [0, count)" {
  run _clockify_index_in_range 0 3
  [ "$status" -eq 0 ]
  run _clockify_index_in_range 2 3
  [ "$status" -eq 0 ]
}

@test "_clockify_index_in_range rejects the upper bound, negative, non-numeric, and empty-count values" {
  run _clockify_index_in_range 3 3
  [ "$status" -ne 0 ]
  run _clockify_index_in_range -1 3
  [ "$status" -ne 0 ]
  run _clockify_index_in_range abc 3
  [ "$status" -ne 0 ]
  run _clockify_index_in_range 0 0
  [ "$status" -ne 0 ]
}

@test "_clockify_resume_body_json includes projectId/taskId/tagIds when present" {
  local entry='{"description":"Write report","projectId":"p2","taskId":"t1","tagIds":["tag1","tag2"]}'
  run _clockify_resume_body_json "$entry" "2026-07-10T08:00:00Z"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.start == "2026-07-10T08:00:00Z"'
  echo "$output" | jq -e '.description == "Write report"'
  echo "$output" | jq -e '.projectId == "p2"'
  echo "$output" | jq -e '.taskId == "t1"'
  echo "$output" | jq -e '.tagIds == ["tag1","tag2"]'
}

@test "_clockify_resume_body_json omits projectId/taskId/tagIds when absent" {
  local entry='{"description":"","projectId":null,"taskId":null,"tagIds":[]}'
  run _clockify_resume_body_json "$entry" "2026-07-10T08:00:00Z"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.description == ""'
  echo "$output" | jq -e 'has("projectId") | not'
  echo "$output" | jq -e 'has("taskId") | not'
  echo "$output" | jq -e 'has("tagIds") | not'
}

@test "_clockify_resume_body_json safely escapes a description with quotes and shell metacharacters" {
  local entry='{"description":"Task\" ; rm -rf / - \"Evil","projectId":null,"taskId":null,"tagIds":[]}'
  run _clockify_resume_body_json "$entry" "2026-07-10T08:00:00Z"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.description | contains("rm -rf")'
}

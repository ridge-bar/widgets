#!/usr/bin/env bats
# Runs the vendored clockify_parse.py against fixture Clockify time-entries
# JSON and asserts both its stdout summary and the cache JSON it writes.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
  CACHE="$(mktemp)"
}

teardown() {
  rm -f "$CACHE"
}

@test "clockify_parse.py: running entry, de-dup, no-description fallback, and truncation" {
  run bash -c "python3 '${PLUGIN_DIR}/clockify_parse.py' '${CACHE}' 10 < '${FIXTURES}/entries_running.json'"
  [ "$status" -eq 0 ]
  expected=$'RUNNING\nTeam · Standup\nDocs · Write report\n(no description)\n1234567890123456789012345…'
  [ "$output" = "$expected" ]

  run jq -e '.running == true' "$CACHE"
  [ "$status" -eq 0 ]
  run jq -r '.currentLabel' "$CACHE"
  [ "$output" = "Team · Standup" ]
  run jq -e '.history | length == 3' "$CACHE"
  [ "$status" -eq 0 ]
}

@test "clockify_parse.py: de-duplicates by description+projectId, excluding the running entry" {
  run bash -c "python3 '${PLUGIN_DIR}/clockify_parse.py' '${CACHE}' 10 < '${FIXTURES}/entries_running.json'"
  [ "$status" -eq 0 ]
  # a1 and a2 share description "Write report" + projectId "p2"; only the
  # first (a1) should survive into history.
  run jq -e '[.history[].description] == ["Write report", "", "12345678901234567890123456789"]' "$CACHE"
  [ "$status" -eq 0 ]
  # d1 duplicates the running entry's (description, projectId) key and must
  # not appear in history at all.
  run jq -e '[.history[] | select(.description == "Standup")] | length == 0' "$CACHE"
  [ "$status" -eq 0 ]
}

@test "clockify_parse.py: no description/project falls back to '(no description)'" {
  run bash -c "python3 '${PLUGIN_DIR}/clockify_parse.py' '${CACHE}' 10 < '${FIXTURES}/entries_running.json'"
  [ "$status" -eq 0 ]
  run jq -e '.history[1].label == "(no description)"' "$CACHE"
  [ "$status" -eq 0 ]
}

@test "clockify_parse.py: truncates a description over 26 chars with an ellipsis" {
  run bash -c "python3 '${PLUGIN_DIR}/clockify_parse.py' '${CACHE}' 10 < '${FIXTURES}/entries_running.json'"
  [ "$status" -eq 0 ]
  run jq -r '.history[2].label' "$CACHE"
  [ "$output" = "1234567890123456789012345…" ]
  # Original description is preserved unabridged in the cache, only the
  # display label is truncated.
  run jq -r '.history[2].description' "$CACHE"
  [ "$output" = "12345678901234567890123456789" ]
}

@test "clockify_parse.py: honors maxrows, truncating the history list" {
  run bash -c "python3 '${PLUGIN_DIR}/clockify_parse.py' '${CACHE}' 2 < '${FIXTURES}/entries_running.json'"
  [ "$status" -eq 0 ]
  expected=$'RUNNING\nTeam · Standup\nDocs · Write report\n(no description)'
  [ "$output" = "$expected" ]
  run jq -e '.history | length == 2' "$CACHE"
  [ "$status" -eq 0 ]
}

@test "clockify_parse.py: IDLE state and 'Not tracking' current label when nothing is running" {
  run bash -c "python3 '${PLUGIN_DIR}/clockify_parse.py' '${CACHE}' 10 < '${FIXTURES}/entries_idle.json'"
  [ "$status" -eq 0 ]
  expected=$'IDLE\nNot tracking\nInbox · Read emails'
  [ "$output" = "$expected" ]
  run jq -e '.running == false' "$CACHE"
  [ "$status" -eq 0 ]
}

@test "clockify_parse.py: exits non-zero and writes nothing on invalid JSON" {
  run bash -c "echo 'not json' | python3 '${PLUGIN_DIR}/clockify_parse.py' '${CACHE}' 10"
  [ "$status" -ne 0 ]
  [ ! -s "$CACHE" ]
}

@test "clockify_parse.py: exits non-zero when stdin is a JSON object instead of an array" {
  run bash -c "echo '{}' | python3 '${PLUGIN_DIR}/clockify_parse.py' '${CACHE}' 10"
  [ "$status" -ne 0 ]
}

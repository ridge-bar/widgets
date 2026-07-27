#!/usr/bin/env bats
# _tasks_parse_noteplan_note() is the exact sed pipeline used by
# refresh_caches() to pull open tasks out of a NotePlan daily note.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  FIXTURE="${BATS_TEST_DIRNAME}/fixtures/noteplan_note.md"
  source "${PLUGIN_DIR}/tasks.sh"
}

@test "extracts open task lines" {
  run _tasks_parse_noteplan_note "$FIXTURE"
  [[ "$output" == *"Buy milk"* ]]
  [[ "$output" == *"Water plants"* ]]
  [[ "$output" == *"Indented open task"* ]]
}

@test "excludes completed [x] task lines" {
  run _tasks_parse_noteplan_note "$FIXTURE"
  [[ "$output" != *"Already done"* ]]
}

@test "excludes non-task lines" {
  run _tasks_parse_noteplan_note "$FIXTURE"
  [[ "$output" != *"Not a task line"* ]]
  [[ "$output" != *"# Today"* ]]
}

@test "strips [[wikilink]] brackets" {
  run _tasks_parse_noteplan_note "$FIXTURE"
  [[ "$output" == *"Call Dentist Office"* ]]
  [[ "$output" != *"[["* ]]
  [[ "$output" != *"]]"* ]]
}

@test "strips multiple wikilinks on one line" {
  run _tasks_parse_noteplan_note "$FIXTURE"
  [[ "$output" == *"Review Project X notes and Project Y notes"* ]]
}

@test "returns exactly the expected open-task count" {
  run _tasks_parse_noteplan_note "$FIXTURE"
  [ "${#lines[@]}" -eq 5 ]
}

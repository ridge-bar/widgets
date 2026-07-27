#!/usr/bin/env bats
# Exercises the Obsidian inbox scan inside refresh_caches() plus urlencode(),
# against a real fixture directory (tests/fixtures/obsidian_inbox).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  FIXTURE_DIR="${BATS_TEST_DIRNAME}/fixtures/obsidian_inbox"
  source "${PLUGIN_DIR}/tasks.sh"
  load_settings
  TMPDIR_TEST="$(mktemp -d)"
  THINGS_CACHE="${TMPDIR_TEST}/things"
  NP_CACHE="${TMPDIR_TEST}/np"
  INBOX_CACHE="${TMPDIR_TEST}/inbox"
  SETTING_things_enabled="false"
  SETTING_noteplan_enabled="false"
  SETTING_obsidian_enabled="true"
  SETTING_obsidian_inbox_dir="$FIXTURE_DIR"
  SETTING_obsidian_vault="Notes"
  SETTING_obsidian_inbox_rel="Notes/00-INBOX"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "urlencode percent-encodes spaces and reserved characters" {
  run urlencode "Grocery List.md"
  [ "$output" = "Grocery%20List.md" ]
}

@test "urlencode leaves unreserved characters untouched" {
  run urlencode "call-plumber_v2.md"
  [ "$output" = "call-plumber_v2.md" ]
}

@test "refresh_caches scans the inbox dir and excludes hidden dotfiles" {
  refresh_caches
  run cat "$INBOX_CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" != *".hidden-note"* ]]
}

@test "refresh_caches produces exactly one uri|title line per visible .md file" {
  refresh_caches
  run wc -l < "$INBOX_CACHE"
  [ "$(echo "$output" | tr -d ' ')" = "2" ]
}

@test "refresh_caches builds a correctly percent-encoded uri for a filename with spaces" {
  refresh_caches
  run grep "Grocery List" "$INBOX_CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" == "obsidian://open?vault=Notes&file=Notes%2F00-INBOX%2FGrocery%20List.md|Grocery List" ]]
}

@test "refresh_caches strips the .md extension from the title" {
  refresh_caches
  run grep "call-plumber" "$INBOX_CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|call-plumber" ]]
}

@test "refresh_caches clears the inbox cache when obsidian is disabled" {
  SETTING_obsidian_enabled="false"
  printf 'stale|Stale Row\n' > "$INBOX_CACHE"
  refresh_caches
  run cat "$INBOX_CACHE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

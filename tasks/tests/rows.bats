#!/usr/bin/env bats
# Exercises _tasks_popup_rows_json() (and its per-section helper), including
# the hostile-title safety property: a title/id with shell metacharacters
# must never break the JSON output and must never become executable in the
# resulting `click` string.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/tasks.sh"
  TMPDIR_TEST="$(mktemp -d)"
  THINGS_CACHE="${TMPDIR_TEST}/things"
  NP_CACHE="${TMPDIR_TEST}/np"
  INBOX_CACHE="${TMPDIR_TEST}/inbox"
  : > "$THINGS_CACHE"; : > "$NP_CACHE"; : > "$INBOX_CACHE"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "all-empty caches produce the single All clear row" {
  run _tasks_popup_rows_json 8
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  [ "$(echo "$output" | jq 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.[0].text')" = "All clear" ]
}

@test "populated sections emit a header row plus item rows, empty sections emit nothing" {
  printf 'id1|Buy milk\n' > "$THINGS_CACHE"
  run _tasks_popup_rows_json 8
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  # Things header + 1 item row; NotePlan/Inbox empty -> no header for them.
  [ "$(echo "$output" | jq 'length')" = "2" ]
  [ "$(echo "$output" | jq -r '.[0].type')" = "header" ]
  [ "$(echo "$output" | jq -r '.[0].text')" = "Things" ]
  [ "$(echo "$output" | jq -r '[.[] | select(.type == "header" and .text == "NotePlan")] | length')" = "0" ]
  [ "$(echo "$output" | jq -r '[.[] | select(.type == "header" and .text == "Inbox")] | length')" = "0" ]
}

@test "row count is capped at max_rows per section" {
  for i in $(seq 1 10); do printf 'id%s|Task %s\n' "$i" "$i" >> "$THINGS_CACHE"; done
  run _tasks_popup_rows_json 3
  [ "$status" -eq 0 ]
  # 1 header + 3 item rows = 4 total.
  [ "$(echo "$output" | jq 'length')" = "4" ]
}

@test "valid JSON output and inert click string for a hostile Things title" {
  printf 'id1|Evil"; rm -rf / #\n' > "$THINGS_CACHE"
  run _tasks_popup_rows_json 8
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  click="$(echo "$output" | jq -r '.[1].click')"
  # click targets the safely-quoted id-derived URI, never the raw title text.
  [[ "$click" == "open 'things:///show?id=id1'"* ]]
  [[ "$click" != *"rm -rf"* ]]
}

@test "valid JSON output and inert click string for a hostile Obsidian title/uri" {
  local marker="${TMPDIR_TEST}/pwned"
  local hostile_title="\`touch ${marker}\` \$(touch ${marker}) '; touch ${marker} ;'"
  printf 'obsidian://open?vault=Notes&file=x|%s\n' "$hostile_title" > "$INBOX_CACHE"
  run _tasks_popup_rows_json 8
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  click="$(jq -r '.[1].click' "$f")"
  text="$(jq -r '.[1].text' "$f")"
  rm -f "$f"
  # click targets only the safely-quoted uri; the hostile text never reaches it.
  [ "$click" = "open 'obsidian://open?vault=Notes&file=x'" ]
  [ "$text" = "$hostile_title" ]
  # click is a single quoted `open <uri>` invocation - no unquoted metachars
  # from the title can appear in it, so it can never execute embedded commands.
  [[ "$click" != *'`'* ]]
  [[ "$click" != *'$('* ]]
  [ ! -e "$marker" ]
}

@test "a hostile title never breaks JSON parsing" {
  printf 'id1|Title with "quotes" and \\backslash and $(cmd) and `tick`\n' > "$THINGS_CACHE"
  printf 'title|Another " hostile '"'"' title\n' > "$INBOX_CACHE"
  run _tasks_popup_rows_json 8
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "NotePlan rows all click the same today-note URI" {
  printf 'Water plants\nCall dentist\n' > "$NP_CACHE"
  run _tasks_popup_rows_json 8
  [ "$status" -eq 0 ]
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  count="$(jq -r '[.[] | select(.click != null) | select(.click | contains("noteplan"))] | length' "$f")"
  rm -f "$f"
  [ "$count" = "2" ]
}

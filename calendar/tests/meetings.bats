#!/usr/bin/env bats
# calendar_meetings.py against a real Calendar DB is not exercised here (not
# portable/permissioned in CI). This only checks the graceful-degradation
# path: any DB-open failure must emit valid JSON with busy=false and a
# placeholder row - never crash the poll loop that invokes it.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# Builds a minimal Calendar DB (OccurrenceCache + CalendarItem) with one
# normal timed meeting and one deliberately malformed row whose
# occurrence_date is far out of datetime's representable range but still
# passes the query's WHERE filter (huge-negative date <= now+24h, end >= now).
_make_malformed_db() {
  local db="$1" now_cd
  now_cd=$(( $(date +%s) - 978307200 ))
  sqlite3 "$db" "
    CREATE TABLE CalendarItem (ROWID INTEGER PRIMARY KEY, all_day INTEGER, availability INTEGER, summary TEXT);
    CREATE TABLE OccurrenceCache (event_id INTEGER, occurrence_date REAL, occurrence_end_date REAL);
    INSERT INTO CalendarItem VALUES (1, 0, 0, 'Normal Meeting');
    INSERT INTO CalendarItem VALUES (2, 0, 0, 'Bad Row');
    INSERT INTO OccurrenceCache VALUES (1, $(( now_cd + 3600 )), $(( now_cd + 7200 )));
    INSERT INTO OccurrenceCache VALUES (2, -1000000000000000000, $(( now_cd + 3600 )));
  "
}

@test "calendar_meetings.py emits valid JSON with busy=false when the DB path does not exist" {
  run env RIDGE_CAL_DB="/nonexistent/path/does-not-exist/Calendar.sqlitedb" \
      RIDGE_CAL_MAXROWS=8 RIDGE_CAL_APP=BusyCal \
      RIDGE_CAL_HEADER_COLOR="#7DCFFF" RIDGE_CAL_ROW_TEXT="#C0CAF5" \
      RIDGE_CAL_ROW_ICON="#565F89" RIDGE_CAL_INPROGRESS="#9ECE6A" \
      python3 "${PLUGIN_DIR}/calendar_meetings.py"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e . >/dev/null   # valid JSON
  echo "$output" | jq -e '.busy == false'
  echo "$output" | jq -e '.rows | length == 2'
  echo "$output" | jq -e '.rows[0].type == "header"'
  echo "$output" | jq -e '.rows[1].text | contains("Full Disk Access")'
}

@test "calendar_meetings.py never crashes and always prints exactly one line of JSON" {
  run env RIDGE_CAL_DB="/nonexistent/path/does-not-exist/Calendar.sqlitedb" \
      python3 "${PLUGIN_DIR}/calendar_meetings.py"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "1" ]
}

@test "calendar_meetings.py honors color/app env overrides in the degraded path" {
  run env RIDGE_CAL_DB="/nonexistent/path/does-not-exist/Calendar.sqlitedb" \
      RIDGE_CAL_HEADER_COLOR="#111111" RIDGE_CAL_ROW_TEXT="#222222" \
      python3 "${PLUGIN_DIR}/calendar_meetings.py"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.rows[0].color == "#111111"'
  echo "$output" | jq -e '.rows[1].color == "#222222"'
}

@test "calendar_meetings.py skips a malformed (out-of-range date) row, keeps the rest, and exits 0" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  _make_malformed_db "${TMP}/cal.sqlitedb"

  run env RIDGE_CAL_DB="${TMP}/cal.sqlitedb" python3 "${PLUGIN_DIR}/calendar_meetings.py"
  [ "$status" -eq 0 ]                              # never crashes on bad row data
  echo "$output" | jq -e . >/dev/null              # valid JSON
  echo "$output" | jq -e '.busy | type == "boolean"'
  echo "$output" | jq -e '.rows[0].type == "header"'
  # The malformed row is dropped; the normal row still renders. Two rows total
  # (header + the one good meeting), never a crash or an empty popup.
  echo "$output" | jq -e '.rows | length == 2'
  echo "$output" | jq -e '[.rows[].text] | any(contains("Normal Meeting"))'
  echo "$output" | jq -e '[.rows[].text] | any(contains("Bad Row")) | not'
}

@test "calendar_meetings.py quotes a spaced calendar_app in the meeting row click" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  _make_malformed_db "${TMP}/cal.sqlitedb"

  run env RIDGE_CAL_DB="${TMP}/cal.sqlitedb" RIDGE_CAL_APP="Microsoft Outlook" \
      python3 "${PLUGIN_DIR}/calendar_meetings.py"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.rows[] | select(.click) | .click] | any(. == "open -a '\''Microsoft Outlook'\''")'
}

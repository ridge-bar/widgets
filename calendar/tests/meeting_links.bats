#!/usr/bin/env bats
# TASK-150: in-progress meetings with a detected meeting link (Google Meet,
# Teams, Zoom, FaceTime) get a "click": "open <link>" row instead of the
# default "open -a <calendar_app>". Covers each provider, first-match
# field-priority order, in-progress-only gating, no-link fallback,
# adversarial shell-injection payloads, and degradation against an
# old-schema DB lacking the link-bearing columns/table entirely.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  TMP="$(mktemp -d)"
  NOW_CD=$(( $(date +%s) - 978307200 ))
}
teardown() { rm -rf "$TMP"; }

# Builds a new-schema Calendar DB: CalendarItem has url/conference_url_detected/
# description/location_id, plus a Location table with a title column. One
# event, timed by offsets (seconds from now; negative start = already begun).
#   $1 db path  $2 start offset  $3 end offset
#   $4 url  $5 conference_url_detected  $6 description  $7 location title
_make_new_schema_db() {
  local db="$1" start_off="$2" end_off="$3" url="$4" conf="$5" desc="$6" loc="$7"
  sqlite3 "$db" "
    CREATE TABLE CalendarItem (ROWID INTEGER PRIMARY KEY, all_day INTEGER, availability INTEGER, summary TEXT, url TEXT, conference_url_detected TEXT, description TEXT, location_id INTEGER);
    CREATE TABLE OccurrenceCache (event_id INTEGER, occurrence_date REAL, occurrence_end_date REAL);
    CREATE TABLE Location (ROWID INTEGER PRIMARY KEY, title TEXT);
    INSERT INTO Location VALUES (1, '${loc}');
    INSERT INTO CalendarItem VALUES (1, 0, 0, 'Meeting', '${url}', '${conf}', '${desc}', 1);
    INSERT INTO OccurrenceCache VALUES (1, $(( NOW_CD + start_off )), $(( NOW_CD + end_off )));
  "
}

# Old-schema DB: no url/conference_url_detected/description/location_id
# columns and no Location table at all - the shape of an older macOS.
_make_old_schema_db() {
  local db="$1" start_off="$2" end_off="$3"
  sqlite3 "$db" "
    CREATE TABLE CalendarItem (ROWID INTEGER PRIMARY KEY, all_day INTEGER, availability INTEGER, summary TEXT);
    CREATE TABLE OccurrenceCache (event_id INTEGER, occurrence_date REAL, occurrence_end_date REAL);
    INSERT INTO CalendarItem VALUES (1, 0, 0, 'Meeting');
    INSERT INTO OccurrenceCache VALUES (1, $(( NOW_CD + start_off )), $(( NOW_CD + end_off )));
  "
}

_run() {
  run env RIDGE_CAL_DB="${TMP}/cal.sqlitedb" python3 "${PLUGIN_DIR}/calendar_meetings.py"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
}

@test "in-progress event with a Google Meet url gets a click that opens the link" {
  _make_new_schema_db "${TMP}/cal.sqlitedb" -600 600 "https://meet.google.com/abc-defg-hij" "" "" ""
  _run
  echo "$output" | jq -e '[.rows[] | select(.text | contains("Meeting"))][0].click == "open https://meet.google.com/abc-defg-hij"'
}

@test "in-progress event with a Teams url (teams.live.com) gets a click that opens the link" {
  _make_new_schema_db "${TMP}/cal.sqlitedb" -600 600 "https://teams.live.com/meet/12345" "" "" ""
  _run
  echo "$output" | jq -e '[.rows[] | select(.text | contains("Meeting"))][0].click == "open https://teams.live.com/meet/12345"'
}

@test "in-progress event with a Zoom link in the location field gets a click that opens the link" {
  _make_new_schema_db "${TMP}/cal.sqlitedb" -600 600 "" "" "" "https://us02web.zoom.us/j/1234567890"
  _run
  echo "$output" | jq -e '[.rows[] | select(.text | contains("Meeting"))][0].click == "open https://us02web.zoom.us/j/1234567890"'
}

@test "in-progress event with a FaceTime link in the description/notes field gets a click that opens the link" {
  _make_new_schema_db "${TMP}/cal.sqlitedb" -600 600 "" "" "https://facetime.apple.com/join?u=abc123" ""
  _run
  echo "$output" | jq -e '[.rows[] | select(.text | contains("Meeting"))][0].click | startswith("open ") and contains("facetime.apple.com/join")'
}

@test "meeting link is extracted from wrapping punctuation" {
  _make_new_schema_db "${TMP}/cal.sqlitedb" -600 600 "" "" "Join here: (https://meet.google.com/abc-defg-hij)." ""
  _run
  echo "$output" | jq -e '[.rows[] | select(.text | contains("Meeting"))][0].click == "open https://meet.google.com/abc-defg-hij"'
}

@test "field order wins over provider order: a Zoom link in url beats a Teams link in notes" {
  _make_new_schema_db "${TMP}/cal.sqlitedb" -600 600 "https://zoom.us/j/1234567890" "" "https://teams.live.com/meet/12345" ""
  _run
  echo "$output" | jq -e '[.rows[] | select(.text | contains("Meeting"))][0].click == "open https://zoom.us/j/1234567890"'
}

@test "upcoming (not yet started) event with a detected link keeps the default calendar_app click" {
  _make_new_schema_db "${TMP}/cal.sqlitedb" 600 1200 "https://meet.google.com/abc-defg-hij" "" "" ""
  _run
  echo "$output" | jq -e '[.rows[] | select(.text | contains("Meeting"))][0].click == "open -a BusyCal"'
}

@test "in-progress event with no detected link keeps the default calendar_app click" {
  _make_new_schema_db "${TMP}/cal.sqlitedb" -600 600 "" "" "" ""
  _run
  echo "$output" | jq -e '[.rows[] | select(.text | contains("Meeting"))][0].click == "open -a BusyCal"'
}

@test "old-schema DB (no link columns/table) degrades cleanly: in-progress event keeps the default click" {
  _make_old_schema_db "${TMP}/cal.sqlitedb" -600 600
  _run
  echo "$output" | jq -e '[.rows[] | select(.text | contains("Meeting"))][0].click == "open -a BusyCal"'
}

# Builds the same new-schema DB as _make_new_schema_db, but inserts the url
# via a Python parameterized query (bind param, not string interpolation)
# fed through an env var - so an adversarial payload (backticks, $(...), ;,
# embedded quotes) never round-trips through bash or SQL string building,
# only ever appearing as inert bound data.
_make_db_with_raw_url() {
  local db="$1" start_off="$2" end_off="$3"
  URL="$4" NOW_CD="$NOW_CD" START_OFF="$start_off" END_OFF="$end_off" python3 - "$db" <<'PYEOF'
import os, sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.executescript("""
    CREATE TABLE CalendarItem (ROWID INTEGER PRIMARY KEY, all_day INTEGER, availability INTEGER, summary TEXT, url TEXT, conference_url_detected TEXT, description TEXT, location_id INTEGER);
    CREATE TABLE OccurrenceCache (event_id INTEGER, occurrence_date REAL, occurrence_end_date REAL);
""")
now_cd = int(os.environ["NOW_CD"])
conn.execute(
    "INSERT INTO CalendarItem VALUES (1, 0, 0, 'Meeting', ?, '', '', NULL)",
    (os.environ["URL"],),
)
conn.execute(
    "INSERT INTO OccurrenceCache VALUES (1, ?, ?)",
    (now_cd + int(os.environ["START_OFF"]), now_cd + int(os.environ["END_OFF"])),
)
conn.commit()
conn.close()
PYEOF
}

# Asserts the click string is properly shell-quoted, not just that a link
# was found: swap the leading "open " for "printf %s " and run the result
# through /bin/sh -c. A vulnerable click would let the payload execute
# (dropping the marker file, or altering the echoed output); shlex.quote'd
# output must round-trip as the literal URL untouched.
_assert_click_is_inert() {
  local click="$1" want_url="$2"
  local marker="${TMP}/pwned"
  local probe="${click/#open /printf %s }"
  run /bin/sh -c "$probe"
  [ ! -e "$marker" ]
  [ "$output" = "$want_url" ]
}

@test "meeting link with backticks is opened literally, not command-substituted" {
  # Bare redirection (">path"), no arguments needed, so the payload stays
  # one \S+ run - a real URL can't contain whitespace either.
  url="https://meet.google.com/abc?x=\`>${TMP}/pwned\`z"
  _make_db_with_raw_url "${TMP}/cal.sqlitedb" -600 600 "$url"
  _run
  click=$(echo "$output" | jq -r '[.rows[] | select(.text | contains("Meeting"))][0].click')
  _assert_click_is_inert "$click" "$url"
}

@test "meeting link with \$(...) is opened literally, not command-substituted" {
  url="https://meet.google.com/abc?x=\$(>${TMP}/pwned)z"
  _make_db_with_raw_url "${TMP}/cal.sqlitedb" -600 600 "$url"
  _run
  click=$(echo "$output" | jq -r '[.rows[] | select(.text | contains("Meeting"))][0].click')
  _assert_click_is_inert "$click" "$url"
}

@test "meeting link with a semicolon and embedded single quote is opened literally" {
  url="https://meet.google.com/abc?x=';>${TMP}/pwned;'z"
  _make_db_with_raw_url "${TMP}/cal.sqlitedb" -600 600 "$url"
  _run
  click=$(echo "$output" | jq -r '[.rows[] | select(.text | contains("Meeting"))][0].click')
  _assert_click_is_inert "$click" "$url"
}

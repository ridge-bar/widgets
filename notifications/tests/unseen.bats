#!/usr/bin/env bats
# Exercises the in-Notification-Center detection: the count comes from the
# usernoted `displayed` blob (what's on screen now), recency-gated against
# `record`. Tests the python helper directly (deterministic
# RIDGE_NOTIF_CUTOFF overrides) and the bash _notif_query wiring end-to-end
# (real wall-clock delivered_date, same fixture-DB pattern as
# plugins/calendar/tests/meetings.bats).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/notifications.sh"
  TMP="$(mktemp -d)"
  DB="${TMP}/db"
}
teardown() { rm -rf "$TMP"; }

_uuid_hex() { python3 -c "import uuid,sys; sys.stdout.write(uuid.uuid4().hex)"; }

# Mirrors the real usernoted db2/db schema for the three tables the helper
# reads: delivered/displayed hold a raw 16-byte-UUID-per-notification blob
# per app_id, record holds one row per notification with its delivery time.
_make_schema() {
  sqlite3 "$1" "
    CREATE TABLE delivered (app_id INTEGER, list BLOB);
    CREATE TABLE displayed (app_id INTEGER, list BLOB);
    CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, delivered_date REAL, presented INTEGER, snooze_fire_date REAL);
  "
}

@test "notifications_unseen.py counts UUIDs in the displayed (Notification Center) list" {
  _make_schema "$DB"
  local u1 u2
  u1="$(_uuid_hex)"; u2="$(_uuid_hex)"
  sqlite3 "$DB" "
    INSERT INTO displayed VALUES (1, X'${u1}${u2}');
    INSERT INTO record VALUES (1, 1, X'${u1}', 1000, 0, NULL);
    INSERT INTO record VALUES (2, 1, X'${u2}', 1000, 0, NULL);
  "
  run env RIDGE_NOTIF_DB="$DB" RIDGE_NOTIF_CUTOFF=0 python3 "${PLUGIN_DIR}/notifications_unseen.py"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "notifications_unseen.py ignores delivered-but-not-displayed (dismissed, not in NC = normal)" {
  _make_schema "$DB"
  local u1 u2
  u1="$(_uuid_hex)"; u2="$(_uuid_hex)"
  sqlite3 "$DB" "
    INSERT INTO delivered VALUES (1, X'${u1}${u2}');
    INSERT INTO record VALUES (1, 1, X'${u1}', 1000, 0, NULL);
    INSERT INTO record VALUES (2, 1, X'${u2}', 1000, 0, NULL);
  "
  run env RIDGE_NOTIF_DB="$DB" RIDGE_NOTIF_CUTOFF=0 python3 "${PLUGIN_DIR}/notifications_unseen.py"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "notifications_unseen.py treats a cleared (NULL) displayed list as zero" {
  _make_schema "$DB"
  sqlite3 "$DB" "INSERT INTO displayed VALUES (1, NULL);"
  run env RIDGE_NOTIF_DB="$DB" RIDGE_NOTIF_CUTOFF=0 python3 "${PLUGIN_DIR}/notifications_unseen.py"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "notifications_unseen.py excludes a UUID whose record row is older than the cutoff (safety net)" {
  _make_schema "$DB"
  local u1
  u1="$(_uuid_hex)"
  sqlite3 "$DB" "
    INSERT INTO displayed VALUES (1, X'${u1}');
    INSERT INTO record VALUES (1, 1, X'${u1}', 100, 0, NULL);
  "
  run env RIDGE_NOTIF_DB="$DB" RIDGE_NOTIF_CUTOFF=200 python3 "${PLUGIN_DIR}/notifications_unseen.py"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "notifications_unseen.py excludes a UUID with no matching record row (unpurgeable safety net)" {
  _make_schema "$DB"
  local u1
  u1="$(_uuid_hex)"
  sqlite3 "$DB" "INSERT INTO displayed VALUES (1, X'${u1}');"
  run env RIDGE_NOTIF_DB="$DB" RIDGE_NOTIF_CUTOFF=0 python3 "${PLUGIN_DIR}/notifications_unseen.py"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "notifications_unseen.py degrades to no output on a missing DB" {
  run env RIDGE_NOTIF_DB="${TMP}/does-not-exist/db" python3 "${PLUGIN_DIR}/notifications_unseen.py"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notifications_unseen.py never creates the DB file when it is absent (existing parent dir)" {
  local target="${TMP}/db"
  [ ! -e "$target" ]
  run env RIDGE_NOTIF_DB="$target" python3 "${PLUGIN_DIR}/notifications_unseen.py"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$target" ]
}

@test "notifications_unseen.py degrades to no output on schema drift (missing tables)" {
  sqlite3 "$DB" "CREATE TABLE nonsense (x INTEGER);"
  run env RIDGE_NOTIF_DB="$DB" python3 "${PLUGIN_DIR}/notifications_unseen.py"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_notif_query end-to-end: a notification in NC tints via _notif_state" {
  _make_schema "$DB"
  local u1 now_cd
  u1="$(_uuid_hex)"
  now_cd=$(( $(date +%s) - 978307200 ))
  sqlite3 "$DB" "
    INSERT INTO displayed VALUES (1, X'${u1}');
    INSERT INTO record VALUES (1, 1, X'${u1}', ${now_cd}, 0, NULL);
  "
  export RIDGE_NOTIF_DB="$DB"
  run _notif_query
  [ "$status" -eq 0 ]
  count="$(_notif_parse_count "$output")"
  [ "$count" = "1" ]
  [ "$(_notif_state "$count")" = "tint" ]
}

@test "_notif_query end-to-end: delivered-but-not-in-NC reports normal" {
  _make_schema "$DB"
  local u1 now_cd
  u1="$(_uuid_hex)"
  now_cd=$(( $(date +%s) - 978307200 ))
  sqlite3 "$DB" "
    INSERT INTO delivered VALUES (1, X'${u1}');
    INSERT INTO record VALUES (1, 1, X'${u1}', ${now_cd}, 0, NULL);
  "
  export RIDGE_NOTIF_DB="$DB"
  run _notif_query
  [ "$status" -eq 0 ]
  count="$(_notif_parse_count "$output")"
  [ "$count" = "0" ]
  [ "$(_notif_state "$count")" = "normal" ]
}

@test "_notif_query end-to-end: cleared displayed list reports normal" {
  _make_schema "$DB"
  sqlite3 "$DB" "INSERT INTO displayed VALUES (1, NULL);"
  export RIDGE_NOTIF_DB="$DB"
  run _notif_query
  [ "$status" -eq 0 ]
  count="$(_notif_parse_count "$output")"
  [ "$count" = "0" ]
  [ "$(_notif_state "$count")" = "normal" ]
}

@test "_notif_query end-to-end: a DB error yields an empty count and normal state" {
  export RIDGE_NOTIF_DB="${TMP}/does-not-exist/db"
  run _notif_query
  [ "$status" -eq 0 ]
  count="$(_notif_parse_count "$output")"
  [ "$count" = "" ]
  [ "$(_notif_state "$count")" = "normal" ]
}

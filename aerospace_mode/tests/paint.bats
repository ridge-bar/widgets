#!/usr/bin/env bats
# _am_paint: reads the state file, sanitizes, and issues the corresponding
# ridge add/set/remove call - the RED-first cases from the task spec (main/
# empty/missing -> remove, a real mode -> add/set with the uppercased label
# and the attention-pill styling flags, and a mode change across two paints).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace_mode.sh"
  load_settings
  TMP="$(mktemp -d)"
  SETTING_state_file="$TMP/mode"
}
teardown() { rm -rf "$TMP"; }

# ridge stub: `query items` answers from $TMP/items.json (default: empty
# store); add/set/remove append their invocation to $TMP/ridge.log.
_stub_ridge() {
  [[ -f "$TMP/items.json" ]] || echo '[]' >"$TMP/items.json"
  ridge() {
    case "$1 $2" in
      "query items") cat "$TMP/items.json" ;;
      *) echo "ridge $*" >>"$TMP/ridge.log" ;;
    esac
  }
}

@test "missing state file hides the badge (remove, no add)" {
  _stub_ridge
  rm -f "$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "ridge remove aerospace_mode.badge" ]
}

@test "empty state file hides the badge" {
  _stub_ridge
  : >"$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  [ "${lines[0]}" = "ridge remove aerospace_mode.badge" ]
}

@test "main mode hides the badge" {
  _stub_ridge
  echo "main" >"$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  [ "${lines[0]}" = "ridge remove aerospace_mode.badge" ]
}

@test "service mode adds the badge anchored before the aerospace container" {
  _stub_ridge
  echo '[{"id":"clock","region":"left"},{"id":"aerospace","region":"left"}]' >"$TMP/items.json"
  echo "service" >"$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  # One add, anchored before the aerospace container - no separate move.
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == ridge\ add\ aerospace_mode.badge* ]]
  [[ "${lines[0]}" == *"--region left"* ]]
  [[ "${lines[0]}" == *"--icon 󰒓"* ]]
  [[ "${lines[0]}" == *"--text SERVICE"* ]]
  [[ "${lines[0]}" == *"--before aerospace"* ]]
  [[ "${lines[0]}" == *"--bg-color theme:warning"* ]]
  [[ "${lines[0]}" == *"--icon-color #12161D"* ]]
  [[ "${lines[0]}" == *"--color #12161D"* ]]
}

@test "service mode adds the badge anchored before the leading workspace item when there is no container" {
  _stub_ridge
  echo '[{"id":"clock","region":"left"},{"id":"aerospace.ws.1.num","region":"left"}]' >"$TMP/items.json"
  echo "service" >"$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"--before aerospace.ws.1.num"* ]]
}

@test "an already-present badge is updated via set and re-anchored before aerospace, not re-added" {
  _stub_ridge
  echo '[{"id":"aerospace_mode.badge","region":"left"},{"id":"aerospace","region":"left"}]' >"$TMP/items.json"
  echo "service" >"$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  # set + move --before aerospace: every paint re-asserts position so a badge
  # displaced by another plugin recovers without a mode cycle through main.
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == ridge\ set\ aerospace_mode.badge* ]]
  [[ "${lines[0]}" == *"--text SERVICE"* ]]
  [ "${lines[1]}" = "ridge move aerospace_mode.badge --before aerospace" ]
}

@test "no aerospace item yet: add with no anchor, no crash (startup race)" {
  _stub_ridge
  echo '[{"id":"vpn.status","region":"right"}]' >"$TMP/items.json"
  echo "service" >"$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == ridge\ add\ aerospace_mode.badge* ]]
  [[ "${lines[0]}" != *"--before"* ]]
  [[ "${lines[0]}" != *"--front"* ]]
}

@test "no aerospace item yet: an already-present badge is set but not moved" {
  _stub_ridge
  echo '[{"id":"aerospace_mode.badge","region":"left"},{"id":"vpn.status","region":"right"}]' >"$TMP/items.json"
  echo "service" >"$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == ridge\ set\ aerospace_mode.badge* ]]
}

@test "trigger sequence: service then main removes what it added" {
  _stub_ridge
  echo '[{"id":"aerospace","region":"left"}]' >"$TMP/items.json"
  echo "service" >"$SETTING_state_file"
  _am_paint
  echo '[{"id":"aerospace_mode.badge","region":"left"},{"id":"aerospace","region":"left"}]' >"$TMP/items.json"
  echo "main" >"$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == ridge\ add* ]]
  [[ "${lines[0]}" == *"--before aerospace"* ]]
  [ "${lines[1]}" = "ridge remove aerospace_mode.badge" ]
}

@test "garbage state-file content hides the badge instead of adding a mangled item" {
  _stub_ridge
  echo '../../etc/passwd' >"$SETTING_state_file"
  _am_paint
  run cat "$TMP/ridge.log"
  [ "${lines[0]}" = "ridge remove aerospace_mode.badge" ]
}

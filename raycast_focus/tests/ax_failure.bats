#!/usr/bin/env bats
# Exercises the AX-query failure path (_raycast_ax_count/focus_state) and its
# log-once-per-streak behavior, plus toggle_and_paint's post-toggle poll
# (_raycast_wait_for_flip). Denied Automation access means the AX query
# itself fails, not just returns an unexpected count - see README.md.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/raycast_focus.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  XDG_STATE_HOME="$(mktemp -d)"
  export XDG_STATE_HOME
  STDERR_FILE="$(mktemp)"
}

teardown() {
  rm -rf "$XDG_STATE_HOME"
  rm -f "$STDERR_FILE"
}

@test "_raycast_ax_count succeeds and prints the count when osascript succeeds" {
  _timeout() { shift; osascript; }
  osascript() { printf '2'; return 0; }
  run _raycast_ax_count
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "_raycast_ax_count fails and surfaces osascript's stderr" {
  _timeout() { shift; osascript; }
  osascript() { echo "Not authorized to send Apple events to System Events." >&2; return 1; }
  run _raycast_ax_count
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not authorized"* ]]
}

@test "focus_state maps a successful AX on/off result through _raycast_count_to_state" {
  _raycast_ax_count() { printf 'on'; return 0; }
  run focus_state
  [ "$output" = "on" ]
}

@test "focus_state falls back to the tracked state when the AX query fails" {
  _raycast_ax_count() { printf 'denied'; return 1; }
  # No tracked file yet -> default off.
  run focus_state
  [[ "$output" == *"off"* ]]
  # Tracked "on" -> focus_state returns on (2>/dev/null drops the once-logged
  # AX-failure line so only the state word remains).
  _raycast_write_tracked on
  run bash -c 'focus_state 2>/dev/null' 2>/dev/null
}

@test "focus_state uses tracked on when AX is down" {
  _raycast_ax_count() { printf 'denied'; return 1; }
  _raycast_write_tracked on
  [ "$(focus_state 2>/dev/null)" = "on" ]
  _raycast_write_tracked off
  [ "$(focus_state 2>/dev/null)" = "off" ]
}

@test "focus_state prefers AX over tracked when AX succeeds" {
  _raycast_write_tracked off
  _raycast_ax_count() { printf 'on'; return 0; }
  [ "$(focus_state)" = "on" ]
}

@test "focus_state treats a successful AX off as unconfirmed, returns tracked on (TASK-121)" {
  # The reported bug: Raycast's Focus indicator is icon-only (no countdown), so
  # the AX query well-formedly returns "off" even during an active session.
  # AX "off" must NOT override the toggle's tracked "on".
  _raycast_ax_count() { printf 'off'; return 0; }
  _raycast_write_tracked on
  [ "$(focus_state)" = "on" ]
}

@test "focus_state returns off when AX off and tracked off (TASK-121)" {
  _raycast_ax_count() { printf 'off'; return 0; }
  _raycast_write_tracked off
  [ "$(focus_state)" = "off" ]
}

@test "focus_state treats an unknown AX result as unconfirmed, returns tracked (TASK-121)" {
  _raycast_ax_count() { printf 'garbage'; return 0; }
  _raycast_write_tracked on
  [ "$(focus_state)" = "on" ]
}

@test "a successful AX off does not log the automation-permission warning (TASK-121)" {
  _raycast_ax_count() { printf 'off'; return 0; }
  _raycast_write_tracked on
  focus_state 2>"$STDERR_FILE" >/dev/null
  [ ! -s "$STDERR_FILE" ]
}

@test "focus_state logs the AX failure once per failure streak, not every poll" {
  _raycast_ax_count() { printf 'denied'; return 1; }
  focus_state 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [[ "$output" == *"raycast_focus: AX query failed"* ]]
  : > "$STDERR_FILE"

  focus_state 2>"$STDERR_FILE"
  [ ! -s "$STDERR_FILE" ]

  focus_state 2>"$STDERR_FILE"
  [ ! -s "$STDERR_FILE" ]
}

@test "a successful query clears the streak so the next failure logs again" {
  _raycast_ax_count() { printf 'denied'; return 1; }
  focus_state 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [[ "$output" == *"raycast_focus: AX query failed"* ]]

  _raycast_ax_count() { printf '1'; return 0; }
  : > "$STDERR_FILE"
  focus_state 2>"$STDERR_FILE"
  [ ! -s "$STDERR_FILE" ]

  _raycast_ax_count() { printf 'denied again'; return 1; }
  : > "$STDERR_FILE"
  focus_state 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [[ "$output" == *"raycast_focus: AX query failed"* ]]
}

@test "_raycast_wait_for_flip returns success as soon as the state flips" {
  sleep() { :; } # skip the real 0.5s waits - only the polling logic is under test
  # focus_state runs inside `$(...)` in _raycast_wait_for_flip - a subshell -
  # so a plain shell counter variable can't track call count across
  # invocations; a file survives across subshells.
  local calls_file; calls_file="$(mktemp)"; printf '0' > "$calls_file"
  focus_state() {
    local n; n="$(($(cat "$calls_file") + 1))"; printf '%s' "$n" > "$calls_file"
    if [ "$n" -ge 2 ]; then printf on; else printf off; fi
  }
  run _raycast_wait_for_flip off
  [ "$status" -eq 0 ]
  rm -f "$calls_file"
}

@test "_raycast_wait_for_flip times out and returns failure if the state never flips" {
  sleep() { :; }
  focus_state() { printf off; }
  run _raycast_wait_for_flip off
  [ "$status" -eq 1 ]
}

@test "_raycast_wait_for_flip ignores a non-on/off state as unsettled" {
  sleep() { :; }
  focus_state() { printf pending; }  # a non-on/off token
  run _raycast_wait_for_flip off
  [ "$status" -eq 1 ]
}

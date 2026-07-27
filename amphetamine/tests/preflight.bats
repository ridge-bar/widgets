#!/usr/bin/env bats
# Exercises the preflight gate (_amph_preflight) and toggle_and_paint's
# refuse-to-toggle-on-failure / log-once-per-streak / warn-paint behavior.
# A malformed AppleEvent sent to Amphetamine without Automation approval has
# previously forced a full re-login - these tests lock in that toggle_session
# is never reached unless _amph_preflight succeeds first.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/amphetamine.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  XDG_STATE_HOME="$(mktemp -d)"
  export XDG_STATE_HOME
  CALL_LOG="$(mktemp)"
  STDERR_FILE="$(mktemp)"
  # Spies: record which paint/toggle path toggle_and_paint actually took,
  # without shelling out to the real osascript/ridge.
  toggle_session() { printf 'toggle_session\n' >> "$CALL_LOG"; }
  paint_state() { printf 'paint_state\n' >> "$CALL_LOG"; }
  paint_warn() { printf 'paint_warn\n' >> "$CALL_LOG"; }
}

teardown() {
  rm -rf "$XDG_STATE_HOME"
  rm -f "$CALL_LOG" "$STDERR_FILE"
}

@test "_amph_preflight succeeds and prints nothing when osascript succeeds" {
  osascript() { return 0; }
  run _amph_preflight
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_amph_preflight fails and surfaces osascript's stderr" {
  osascript() { echo "Not authorized to send Apple events to Amphetamine." >&2; return 1; }
  run _amph_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not authorized"* ]]
}

@test "toggle_and_paint toggles and paints normally when preflight succeeds" {
  _amph_preflight() { return 0; }
  toggle_and_paint 2>"$STDERR_FILE"
  run cat "$CALL_LOG"
  [[ "$output" == *"toggle_session"* ]]
  [[ "$output" == *"paint_state"* ]]
  [[ "$output" != *"paint_warn"* ]]
  [ ! -s "$STDERR_FILE" ]
}

@test "toggle_and_paint refuses to toggle and paints the warning state when preflight fails" {
  _amph_preflight() { printf 'not authorized'; return 1; }
  toggle_and_paint 2>"$STDERR_FILE"
  run cat "$CALL_LOG"
  [[ "$output" != *"toggle_session"* ]]
  [[ "$output" != *"paint_state"* ]]
  [[ "$output" == *"paint_warn"* ]]
  run cat "$STDERR_FILE"
  [[ "$output" == *"amphetamine: preflight failed"* ]]
  [[ "$output" == *"not authorized"* ]]
}

@test "toggle_and_paint logs the preflight failure once per failure streak, not every call" {
  _amph_preflight() { printf 'still not authorized'; return 1; }
  toggle_and_paint 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [[ "$output" == *"amphetamine: preflight failed"* ]]
  : > "$STDERR_FILE"

  toggle_and_paint 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [ -z "$output" ]

  toggle_and_paint 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [ -z "$output" ]
}

@test "a successful preflight clears the streak so the next failure logs again" {
  _amph_preflight() { printf 'not authorized'; return 1; }
  toggle_and_paint 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [[ "$output" == *"amphetamine: preflight failed"* ]]

  _amph_preflight() { return 0; }
  : > "$STDERR_FILE"
  toggle_and_paint 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [ -z "$output" ]

  _amph_preflight() { printf 'not authorized again'; return 1; }
  : > "$STDERR_FILE"
  toggle_and_paint 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [[ "$output" == *"amphetamine: preflight failed"* ]]
}

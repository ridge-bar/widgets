#!/usr/bin/env bats
# Exercises the real toggle_session (unlike preflight.bats, which spies on it
# to test toggle_and_paint's gating logic) - specifically that its osascript
# stderr is captured and logged, not blinded with >/dev/null 2>&1.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/amphetamine.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  STDERR_FILE="$(mktemp)"
}

teardown() {
  rm -f "$STDERR_FILE"
}

@test "toggle_session logs osascript's stderr on failure instead of blinding it" {
  is_active() { return 1; }
  osascript() { echo "execution error: not authorized" >&2; return 1; }
  toggle_session 2>"$STDERR_FILE"
  run cat "$STDERR_FILE"
  [[ "$output" == *"amphetamine: toggle_session osascript failed"* ]]
  [[ "$output" == *"not authorized"* ]]
}

@test "toggle_session stays silent when osascript succeeds" {
  is_active() { return 1; }
  osascript() { return 0; }
  toggle_session 2>"$STDERR_FILE"
  [ ! -s "$STDERR_FILE" ]
}

@test "toggle_session calls the end-session AppleScript when a session is active" {
  is_active() { return 0; }
  OSA_ARGS_FILE="$(mktemp)"
  osascript() { printf '%s\n' "$*" > "$OSA_ARGS_FILE"; }
  toggle_session
  run cat "$OSA_ARGS_FILE"
  [[ "$output" == *"end session"* ]]
  rm -f "$OSA_ARGS_FILE"
}

@test "toggle_session calls the start-new-session AppleScript when no session is active" {
  is_active() { return 1; }
  OSA_ARGS_FILE="$(mktemp)"
  osascript() { printf '%s\n' "$*" > "$OSA_ARGS_FILE"; }
  toggle_session
  run cat "$OSA_ARGS_FILE"
  [[ "$output" == *"start new session"* ]]
  rm -f "$OSA_ARGS_FILE"
}

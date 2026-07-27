#!/usr/bin/env bats
# Exercises the clock.time click: opens macOS Notification Center via an
# AXPress on the Clock menu-bar extra, selected by its locale-independent
# AXIdentifier ("com.apple.menuextra.clock") rather than its localized
# "Clock" description. Re-exec'd through CLOCK_OPEN_NC=1 (build_reexec_cmd),
# same pattern as the sibling raycast_focus/media plugins. AX failures (no
# Accessibility permission) must degrade silently - no error popup - and log
# once per failure streak, mirroring raycast_focus/tests/ax_failure.bats.
# Ported from plugins/calendar/tests/click.bats (TASK-153) when TIME was
# split out of calendar into this standalone clock plugin.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/clock.sh"
  XDG_STATE_HOME="$(mktemp -d)"
  export XDG_STATE_HOME
  STDERR_FILE="$(mktemp)"
}

teardown() {
  rm -rf "$XDG_STATE_HOME"
  rm -f "$STDERR_FILE"
}

@test "the clock.time ridge add line carries a --click re-exec for CLOCK_OPEN_NC" {
  block="$(sed -n '/ridge add "\$ITEM_ID"/,/|| true/p' "${PLUGIN_DIR}/clock.sh")"
  [ -n "$block" ]
  [[ "$block" == *'--click "$click_cmd"'* ]]
  grep -q 'click_cmd="\$(build_reexec_cmd "CLOCK_OPEN_NC=1"' "${PLUGIN_DIR}/clock.sh"
}

@test "build_reexec_cmd embeds the env assignment and script path" {
  run build_reexec_cmd "CLOCK_OPEN_NC=1" "/path/to/clock.sh" ""
  [[ "$output" == *"CLOCK_OPEN_NC=1"* ]]
  [[ "$output" == *"/path/to/clock.sh"* ]]
}

@test "_clock_open_notification_center succeeds when osascript succeeds" {
  _timeout() { shift; "$@"; }
  osascript() { return 0; }
  run _clock_open_notification_center
  [ "$status" -eq 0 ]
}

@test "_clock_open_notification_center prints nothing on success" {
  _timeout() { shift; "$@"; }
  osascript() { echo "should never be seen" >&2; return 0; }
  _clock_open_notification_center >"${STDERR_FILE}.out" 2>"$STDERR_FILE"
  [ ! -s "$STDERR_FILE" ]
  [ ! -s "${STDERR_FILE}.out" ]
  rm -f "${STDERR_FILE}.out"
}

@test "_clock_open_notification_center logs the AX failure once per failure streak" {
  _timeout() { shift; "$@"; }
  osascript() { echo "not authorized" >&2; return 1; }
  _clock_open_notification_center 2>"$STDERR_FILE" || true
  run cat "$STDERR_FILE"
  [[ "$output" == *"clock:"* ]]
  [[ "$output" == *"Accessibility"* ]]
  : > "$STDERR_FILE"

  _clock_open_notification_center 2>"$STDERR_FILE" || true
  [ ! -s "$STDERR_FILE" ]
}

@test "a successful call clears the streak so the next failure logs again" {
  _timeout() { shift; "$@"; }
  osascript() { echo "not authorized" >&2; return 1; }
  _clock_open_notification_center 2>"$STDERR_FILE" || true
  [ -s "$STDERR_FILE" ]

  osascript() { return 0; }
  _clock_open_notification_center 2>/dev/null

  osascript() { echo "not authorized again" >&2; return 1; }
  : > "$STDERR_FILE"
  _clock_open_notification_center 2>"$STDERR_FILE" || true
  [ -s "$STDERR_FILE" ]
}

@test "main() dispatches CLOCK_OPEN_NC=1 straight to the handler, without requiring RIDGE_SOCKET" {
  run env CLOCK_OPEN_NC=1 bash -c '
    source "'"${PLUGIN_DIR}"'/clock.sh"
    _timeout() { shift; "$@"; }
    osascript() { return 0; }
    ridge() { echo "ridge should not be called: $*" >&2; return 1; }
    unset RIDGE_SOCKET
    main
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"ridge should not be called"* ]]
}

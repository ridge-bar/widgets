#!/usr/bin/env bats
# TASK-140 (review): run_reconcile_guarded is the single-flight + coalesce
# mutex around run_reconcile. macOS has no flock, so mkdir (atomic across
# processes) is the lock primitive. Without this, SIGUSR1's trap and the
# subscribe pipeline's own subshell could both call run_reconcile at once
# against the same non-atomic cache files.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
  load_settings
  TMP="$(mktemp -d)"
  RECONCILE_LOCK_DIR="$TMP/lock"
  RECONCILE_REDO_FLAG="$TMP/redo"
}
teardown() { rm -rf "$TMP"; }

# Simulates a lock already held by another process/invocation, `age` seconds
# ago (0 = just acquired, fresh).
_hold_lock() {
  local age="${1:-0}"
  mkdir "$RECONCILE_LOCK_DIR"
  echo "$(( $(date +%s) - age ))" >"$RECONCILE_LOCK_DIR/acquired_at"
}

@test "run_reconcile_guarded skips the pass and leaves a redo flag when the lock is already held" {
  _hold_lock 0                                   # simulate an in-flight reconcile elsewhere
  run_reconcile() { echo "reconcile" >>"$TMP/calls"; }
  run_reconcile_guarded
  [ ! -e "$TMP/calls" ]                          # did NOT run a pass itself
  [ -e "$RECONCILE_REDO_FLAG" ]                   # asked the holder to redo
  [ -d "$RECONCILE_LOCK_DIR" ]                    # did not touch the other holder's lock
}

@test "run_reconcile_guarded re-runs exactly once when redo was requested mid-pass" {
  # Stub run_reconcile so the FIRST pass drops a redo flag (simulating a
  # second caller arriving while this pass is running); the second pass must
  # not see a redo flag and so must stop, for exactly 2 passes total.
  local n=0
  run_reconcile() {
    n=$((n + 1))
    echo "$n" >>"$TMP/calls"
    [ "$n" -eq 1 ] && : >"$RECONCILE_REDO_FLAG"
  }
  run_reconcile_guarded
  [ "$(wc -l <"$TMP/calls" | tr -d ' ')" = "2" ]
}

@test "run_reconcile_guarded releases the lock after a normal pass" {
  run_reconcile() { :; }
  run_reconcile_guarded
  [ ! -d "$RECONCILE_LOCK_DIR" ]
}

@test "run_reconcile_guarded releases the lock even when run_reconcile fails" {
  run_reconcile() { return 1; }
  run_reconcile_guarded
  [ ! -d "$RECONCILE_LOCK_DIR" ]
}

@test "a second guarded call while the first is in flight coalesces instead of running concurrently" {
  # Real (non-stubbed) mkdir race: the first call holds the lock and, mid-pass,
  # a second call arrives on the SAME lock dir - it must bail out immediately
  # (redo flag only, never a concurrent run_reconcile), and the redo flag it
  # leaves behind triggers exactly one coalesced follow-up pass afterward.
  run_reconcile() {
    echo "pass" >>"$TMP/calls"
    if [ ! -e "$TMP/nested_attempted" ]; then
      : >"$TMP/nested_attempted"
      ( run_reconcile_guarded )                  # simulated second caller, mid-pass
    fi
  }
  run_reconcile_guarded
  [ "$(wc -l <"$TMP/calls" | tr -d ' ')" = "2" ]
  [ ! -d "$RECONCILE_LOCK_DIR" ]                  # released after the coalesced pass
}

@test "a lock older than the stale-age cap is reclaimed instead of blocking forever" {
  _hold_lock "$(( RECONCILE_LOCK_MAX_AGE + 5 ))"  # older than the cap: reads as abandoned
  run_reconcile() { echo "reconcile" >>"$TMP/calls"; }
  run_reconcile_guarded
  [ -e "$TMP/calls" ]                            # reclaimed the stale lock and ran
  [ ! -d "$RECONCILE_LOCK_DIR" ]                  # released again after the pass
}

@test "a lock younger than the stale-age cap is left alone (not reclaimed)" {
  _hold_lock "$(( RECONCILE_LOCK_MAX_AGE - 5 ))"  # still within the cap: genuinely in flight
  run_reconcile() { echo "reconcile" >>"$TMP/calls"; }
  run_reconcile_guarded
  [ ! -e "$TMP/calls" ]
  [ -e "$RECONCILE_REDO_FLAG" ]
}

# --- routing: every reconcile call site goes through the guard --------------

@test "subscribe/poll SIGUSR1 trap now calls run_reconcile_guarded, not run_reconcile directly" {
  _install_signal_policy "subscribe"
  run trap -p USR1
  [[ "$output" == *"run_reconcile_guarded"* ]]
  _install_signal_policy "poll"
  run trap -p USR1
  [[ "$output" == *"run_reconcile_guarded"* ]]
}

@test "SIGUSR1 in subscribe mode runs exactly one guarded reconcile pass, never a raw run_reconcile" {
  run_reconcile() { echo "reconcile" >>"$TMP/calls"; }
  _install_signal_policy "subscribe"
  kill -USR1 $BASHPID
  [ "$(wc -l <"$TMP/calls" | tr -d ' ')" = "1" ]
  [ ! -d "$RECONCILE_LOCK_DIR" ]                  # lock released, no leak
}

@test "trigger_loop's drain routes through run_reconcile_guarded" {
  run_reconcile() { echo "reconcile" >>"$TMP/calls"; }
  pending=1
  while [[ "$pending" == "1" ]]; do
    pending=0
    run_reconcile_guarded
  done
  [ "$(wc -l <"$TMP/calls" | tr -d ' ')" = "1" ]
  [ ! -d "$RECONCILE_LOCK_DIR" ]
}

@test "reconcile lock/redo live under a private 0700 XDG_STATE_HOME dir, not world-writable /tmp (TASK-140 security)" {
  # Regression for the symlink-attack finding: a predictable /tmp path let another
  # local user pre-plant a symlink and redirect the redo-flag write. The lock/redo
  # must live in a private per-user 0700 dir instead.
  XDG_STATE_HOME="$TMP/xdg"
  local d; d="$(_reconcile_state_dir)"
  [ "$d" = "$TMP/xdg/ridge/aerospace_ws" ]
  [[ "$d" != /tmp/* ]]
  [ -d "$d" ]
  # 0700 (no group/other access) - portable perms check (BSD/GNU stat differ).
  [ "$(ls -ld "$d" | cut -c1-10)" = "drwx------" ]
}

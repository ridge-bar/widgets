#!/usr/bin/env bats
# TASK-130: subscribe_loop's connect-time reconcile self-heals a transient
# failure (API socket not yet renamed onto its public path, or AeroSpace
# still cold-starting) by retrying until a workspace bubble actually paints,
# instead of relying on `aerospace subscribe`'s event stream to ever fire.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
  load_settings
  CALL_LOG="$(mktemp)"
}
teardown() { rm -f "$CALL_LOG"; }

# --- _reconcile_painted_workspace --------------------------------------------

@test "_reconcile_painted_workspace is true when ridge reports a workspace item" {
  ridge() { echo '[{"id":"aerospace_ws.1.num","text":"1"},{"id":"other","text":"x"}]'; }
  _reconcile_painted_workspace
}

@test "_reconcile_painted_workspace is false on an empty item list" {
  ridge() { echo '[]'; }
  ! _reconcile_painted_workspace
}

@test "_reconcile_painted_workspace is false when ridge itself fails (socket not ready)" {
  ridge() { return 1; }
  ! _reconcile_painted_workspace
}

@test "_reconcile_painted_workspace is false when no item id has the aerospace_ws. prefix" {
  ridge() { echo '[{"id":"aerospace.window.1","text":"x"},{"id":"aerospace.status","text":"down"}]'; }
  ! _reconcile_painted_workspace
}

# --- _reconcile_until_painted ------------------------------------------------

@test "_reconcile_until_painted stops after the first attempt when it already painted" {
  run_reconcile() { echo "run_reconcile" >>"$CALL_LOG"; }
  ridge() { echo '[{"id":"aerospace_ws.1.num"}]'; }
  _reconcile_until_painted 5 0.01
  [ "$(wc -l <"$CALL_LOG" | tr -d ' ')" = "1" ]
}

@test "_reconcile_until_painted retries until a later attempt paints, then stops" {
  local attempt_file; attempt_file="$(mktemp)"; echo 0 >"$attempt_file"
  run_reconcile() {
    local n; n="$(<"$attempt_file")"; n=$((n + 1)); echo "$n" >"$attempt_file"
    echo "run_reconcile" >>"$CALL_LOG"
  }
  # Only the third and later reconciles find a painted workspace.
  ridge() {
    local n; n="$(<"$attempt_file")"
    if [[ "$n" -ge 3 ]]; then echo '[{"id":"aerospace_ws.1.num"}]'; else echo '[]'; fi
  }
  _reconcile_until_painted 5 0.01
  [ "$(wc -l <"$CALL_LOG" | tr -d ' ')" = "3" ]
  rm -f "$attempt_file"
}

@test "_reconcile_until_painted gives up after the attempt cap and returns failure" {
  run_reconcile() { echo "run_reconcile" >>"$CALL_LOG"; }
  ridge() { echo '[]'; }
  run _reconcile_until_painted 4 0.01
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$CALL_LOG" | tr -d ' ')" = "4" ]
}

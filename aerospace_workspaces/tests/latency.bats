#!/usr/bin/env bats
# Focus-change latency: the fast-path highlight, the leading-edge event
# handling, and the osascript position-cache reuse.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
  source "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
  load_settings
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# --- _fast_path_focus -------------------------------------------------------

# aerospace stub: focused-workspace query answers from $TMP/focused.
_stub_focus_query() {
  aerospace() {
    if [[ "$1" == "list-workspaces" ]]; then cat "$TMP/focused"; else return 1; fi
  }
  ridge() { echo "ridge $*" >>"$TMP/ridge.log"; }
}

@test "fast-path moves the highlight off the old pill and onto the new one" {
  _stub_focus_query
  LAST_FOCUSED_WS="1"
  LAST_FOCUSED_WS_MON="DELL"
  printf 'web\tDELL\n' >"$TMP/focused"
  _fast_path_focus
  run cat "$TMP/ridge.log"
  [ "${lines[0]}" = "ridge set aerospace_ws.DELL.1.num --highlight off" ]
  [ "${lines[1]}" = "ridge set aerospace_ws.DELL.web.num --highlight on" ]
  [ "$LAST_FOCUSED_WS" = "web" ]
  [ "$LAST_FOCUSED_WS_MON" = "DELL" ]
}

# A workspace switch that ALSO crosses monitors (the old pill and the new
# pill live on different monitors) must unhighlight the id keyed by the OLD
# monitor, not the current one.
@test "fast-path unhighlights the old pill's id using the monitor it was last painted on" {
  _stub_focus_query
  LAST_FOCUSED_WS="1"
  LAST_FOCUSED_WS_MON="Built-in"
  printf 'web\tDELL\n' >"$TMP/focused"
  _fast_path_focus
  run cat "$TMP/ridge.log"
  [ "${lines[0]}" = "ridge set aerospace_ws.Built-in.1.num --highlight off" ]
  [ "${lines[1]}" = "ridge set aerospace_ws.DELL.web.num --highlight on" ]
}

@test "fast-path with no prior focus only highlights the new pill" {
  _stub_focus_query
  LAST_FOCUSED_WS=""
  LAST_FOCUSED_WS_MON=""
  printf '2\tDELL\n' >"$TMP/focused"
  _fast_path_focus
  run cat "$TMP/ridge.log"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "ridge set aerospace_ws.DELL.2.num --highlight on" ]
}

@test "fast-path no-ops when focus is unchanged or the query fails" {
  _stub_focus_query
  LAST_FOCUSED_WS="1"
  LAST_FOCUSED_WS_MON="DELL"
  printf '1\tDELL\n' >"$TMP/focused"
  _fast_path_focus
  [ ! -e "$TMP/ridge.log" ]
  : >"$TMP/focused"                    # empty answer = failed query
  _fast_path_focus
  [ ! -e "$TMP/ridge.log" ]
  [ "$LAST_FOCUSED_WS" = "1" ]
}

@test "fast-path sanitizes the workspace name used in the item id" {
  _stub_focus_query
  LAST_FOCUSED_WS=""
  LAST_FOCUSED_WS_MON=""
  printf 'w s;1\tDELL U2720Q\n' >"$TMP/focused"
  _fast_path_focus
  run cat "$TMP/ridge.log"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "ridge set aerospace_ws.DELL_U2720Q.w_s_1.num --highlight on" ]
}

# --- _on_subscribe_event (leading edge + trailing coalesce) ------------------

_stub_event_stages() {
  _fast_path_focus() { echo "fastpath" >>"$TMP/stage.log"; }
  run_reconcile() { echo "reconcile" >>"$TMP/stage.log"; }
}

@test "event handling is leading-edge: fast-path then reconcile, no trailing pass for a lone event" {
  _stub_event_stages
  _on_subscribe_event </dev/null
  run cat "$TMP/stage.log"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "fastpath" ]
  [ "${lines[1]}" = "reconcile" ]
}

@test "a queued event burst coalesces into exactly one trailing pass" {
  _stub_event_stages
  _on_subscribe_event <<<$'event2\nevent3\nevent4'
  run cat "$TMP/stage.log"
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[2]}" = "fastpath" ]
  [ "${lines[3]}" = "reconcile" ]
}

# --- osascript position-cache reuse in run_reconcile -------------------------

# Full stub set so run_reconcile runs end to end against the fixtures.
_stub_reconcile_world() {
  aerospace() {
    case "$1" in
      list-monitors)   cat "$FIXTURES/monitors.tsv" ;;
      list-workspaces)
        if [[ "$*" == *"--focused"* ]]; then echo "1"; else cat "$FIXTURES/workspaces.tsv"; fi ;;
      list-windows)
        if [[ "$*" == *"--focused"* ]]; then echo "100"; else cat "$TMP/windows.tsv"; fi ;;
    esac
  }
  ridge() {
    case "$1 $2" in
      "query items")    cat "$FIXTURES/items.json" ;;
      "query brackets") cat "$FIXTURES/brackets.json" ;;
      *) : ;;
    esac
  }
  osascript() { echo "call" >>"$TMP/osascript.log"; printf '100\t0\t0\n'; }
  cp "$FIXTURES/windows.tsv" "$TMP/windows.tsv"
}

@test "osascript is skipped when the window snapshot is unchanged, at most once in a row" {
  _stub_reconcile_world
  run_reconcile
  run_reconcile          # same window set: reuse the cached position map
  [ "$(wc -l <"$TMP/osascript.log" | tr -d ' ')" -eq 1 ]
  run_reconcile          # reuse is bounded to one consecutive pass
  [ "$(wc -l <"$TMP/osascript.log" | tr -d ' ')" -eq 2 ]
}

@test "osascript re-runs when the window set changes" {
  _stub_reconcile_world
  run_reconcile
  printf '1\t105\tkitty\ttiling\n' >>"$TMP/windows.tsv"
  run_reconcile
  [ "$(wc -l <"$TMP/osascript.log" | tr -d ' ')" -eq 2 ]
}

@test "a failed list-windows query skips the pass and leaves the order cache untouched" {
  _stub_reconcile_world
  ORDER_CACHE_FILE="$TMP/ordercache"
  run_reconcile                                    # healthy pass populates the cache
  cp "$ORDER_CACHE_FILE" "$TMP/ordercache.before"
  aerospace() {                                    # now list-windows fails
    case "$1" in
      list-monitors)   cat "$FIXTURES/monitors.tsv" ;;
      list-workspaces) cat "$FIXTURES/workspaces.tsv" ;;
      list-windows)    return 1 ;;
    esac
  }
  ridge() { echo "ridge $*" >>"$TMP/ridge.mutations"; }
  run_reconcile
  [ ! -e "$TMP/ridge.mutations" ]                  # no queries, no mutations: pass skipped
  run diff "$TMP/ordercache.before" "$ORDER_CACHE_FILE"
  [ "$status" -eq 0 ]
}

@test "an orphaned event loop exits without reconciling when the main process is gone" {
  _stub_event_stages
  true & MAIN_PID=$!                       # a pid that is already dead
  wait "$MAIN_PID" 2>/dev/null || true
  run _on_subscribe_event
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/stage.log" ]                # no fast-path, no reconcile
}

@test "a live event loop is unaffected by the orphan guard" {
  _stub_event_stages
  MAIN_PID=$$
  _on_subscribe_event </dev/null
  run cat "$TMP/stage.log"
  [ "${#lines[@]}" -eq 2 ]
}

# subscribe/poll modes used to SIG_IGN SIGUSR1 (only trigger_loop reconciled
# on it). DisplayManager.onDisplaySetChanged also sends SIGUSR1 on a monitor
# plug/unplug - a subscribe-mode plugin's own event stream never reports
# that, so it must reconcile on the signal too, not just survive it.
@test "subscribe and poll modes reconcile on SIGUSR1 instead of ignoring it" {
  _install_signal_policy "subscribe"
  run trap -p USR1
  [[ "$output" == *"run_reconcile_guarded' SIGUSR1"* ]]
  kill -USR1 $BASHPID                      # survives a real trigger (does not kill bash)
  _install_signal_policy "poll"
  run trap -p USR1
  [[ "$output" == *"run_reconcile_guarded' SIGUSR1"* ]]
}

@test "subscribe mode's SIGUSR1 trap actually runs a reconcile pass" {
  _stub_reconcile_world
  _install_signal_policy "subscribe"
  kill -USR1 $BASHPID
  [ -e "$TMP/osascript.log" ]              # _run_reconcile_pass actually ran
  [ ! -d "$RECONCILE_LOCK_DIR" ]           # guard released the lock, no leak
}

@test "trigger mode leaves USR1 alone for trigger_loop's own handler" {
  trap - USR1
  _install_signal_policy "trigger"
  run trap -p USR1
  [ -z "$output" ]
}

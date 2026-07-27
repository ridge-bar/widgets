#!/usr/bin/env bats
# Focus-change latency: the fast-path highlight, the leading-edge event
# handling, and the osascript position-cache reuse.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
  source "${PLUGIN_DIR}/aerospace-apps-plugin.sh"
  load_settings
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# --- _fast_path_window_focus --------------------------------------------------

# aerospace stub: focused-window query answers from $TMP/focused_win.
_stub_window_focus_query() {
  aerospace() {
    if [[ "$1" == "list-windows" ]]; then cat "$TMP/focused_win"; else return 1; fi
  }
  ridge() { echo "ridge $*" >>"$TMP/ridge.log"; }
  WIN_MAP_FILE="$TMP/winmap"
  printf '100\taerospace_apps.Built-in_Retina_Display.1.icon\n' >"$WIN_MAP_FILE"
  printf '101\taerospace_apps.Built-in_Retina_Display.2.icon\n' >>"$WIN_MAP_FILE"
}

@test "window fast-path moves the highlight via the reconcile-persisted map" {
  _stub_window_focus_query
  LAST_FOCUSED_WIN="100"
  echo "101" >"$TMP/focused_win"
  _fast_path_window_focus
  run cat "$TMP/ridge.log"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "ridge set aerospace_apps.Built-in_Retina_Display.1.icon --highlight off" ]
  [ "${lines[1]}" = "ridge set aerospace_apps.Built-in_Retina_Display.2.icon --highlight on" ]
  [ "$LAST_FOCUSED_WIN" = "101" ]
}

@test "window fast-path no-ops when focus is unchanged, unknown, or the map is empty" {
  _stub_window_focus_query
  LAST_FOCUSED_WIN="101"
  echo "101" >"$TMP/focused_win"           # unchanged
  _fast_path_window_focus
  [ ! -e "$TMP/ridge.log" ]
  echo "999" >"$TMP/focused_win"           # not in the map: reconcile's job
  _fast_path_window_focus
  [ ! -e "$TMP/ridge.log" ]
  [ "$LAST_FOCUSED_WIN" = "101" ]
  : >"$WIN_MAP_FILE"                       # no map yet (before first reconcile)
  echo "100" >"$TMP/focused_win"
  _fast_path_window_focus
  [ ! -e "$TMP/ridge.log" ]
}

@test "desired_state emits a WMAP line per visible-workspace window" {
  run desired_state "${FIXTURES}/monitors.tsv" "${FIXTURES}/workspaces.tsv" "${FIXTURES}/windows.tsv" "100"
  [ "$status" -eq 0 ]
  # windows.tsv: wids 100/101 on visible ws 1, 300 on visible ws web.
  echo "$output" | grep -q $'^WMAP\t100\taerospace_apps.Built-in_Retina_Display.1.icon$'
  echo "$output" | grep -q $'^WMAP\t101\taerospace_apps.Built-in_Retina_Display.2.icon$'
  echo "$output" | grep -q $'^WMAP\t300\t'
  # ws 2 is not visible: its window 200 gets no map entry.
  ! echo "$output" | grep -q $'^WMAP\t200\t'
}

@test "run_reconcile persists the WMAP into WIN_MAP_FILE" {
  _stub_reconcile_world
  WIN_MAP_FILE="$TMP/winmap"
  run_reconcile
  grep -q $'^100\taerospace_apps\.' "$WIN_MAP_FILE"
}

# --- _on_subscribe_event (leading edge + trailing coalesce) ------------------

_stub_event_stages() {
  _fast_path_window_focus() { echo "winfastpath" >>"$TMP/stage.log"; }
  run_reconcile() { echo "reconcile" >>"$TMP/stage.log"; }
}

@test "event handling is leading-edge: fast-path then reconcile, no trailing pass for a lone event" {
  _stub_event_stages
  _on_subscribe_event </dev/null
  run cat "$TMP/stage.log"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "winfastpath" ]
  [ "${lines[1]}" = "reconcile" ]
}

@test "a queued event burst coalesces into exactly one trailing pass" {
  _stub_event_stages
  _on_subscribe_event <<<$'event2\nevent3\nevent4'
  run cat "$TMP/stage.log"
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[2]}" = "winfastpath" ]
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

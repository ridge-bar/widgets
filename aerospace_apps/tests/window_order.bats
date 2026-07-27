#!/usr/bin/env bats
# Unit tests for _order_windows_by_position, the testable seam run_reconcile
# uses to sort each workspace's windows into on-screen (visual) order. The
# osascript/CoreGraphics call itself (window_positions.js) is integration-only
# and not exercised here - these tests feed a positions map from a file.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-apps-plugin.sh"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# windows tsv columns: workspace, window-id, app-name, window-layout.
# positions tsv columns: window-id, x, y.

@test "_order_windows_by_position sorts a workspace's windows by ascending x" {
  printf '1\t300\tSlack\ttiling\n' >"$TMP/windows"
  printf '1\t100\tkitty\ttiling\n' >>"$TMP/windows"
  printf '1\t200\tGoogle Chrome\ttiling\n' >>"$TMP/windows"
  printf '100\t10\t0\n' >"$TMP/positions"
  printf '200\t20\t0\n' >>"$TMP/positions"
  printf '300\t30\t0\n' >>"$TMP/positions"

  run _order_windows_by_position "$TMP/windows" "$TMP/positions"
  [ "$status" -eq 0 ]
  order="$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')"
  [ "$order" = "100 200 300 " ]
}

@test "_order_windows_by_position breaks x ties by ascending y" {
  printf '1\t100\tkitty\ttiling\n' >"$TMP/windows"
  printf '1\t200\tSlack\ttiling\n' >>"$TMP/windows"
  printf '100\t10\t50\n' >"$TMP/positions"
  printf '200\t10\t5\n' >>"$TMP/positions"

  run _order_windows_by_position "$TMP/windows" "$TMP/positions"
  order="$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')"
  [ "$order" = "200 100 " ]
}

@test "_order_windows_by_position sorts a window with no position entry last within its workspace" {
  printf '1\t100\tkitty\ttiling\n' >"$TMP/windows"
  printf '1\t200\tSlack\ttiling\n' >>"$TMP/windows"
  printf '1\t300\tGoogle Chrome\ttiling\n' >>"$TMP/windows"
  printf '100\t50\t0\n' >"$TMP/positions"
  printf '300\t10\t0\n' >>"$TMP/positions"
  # 200 (Slack) has no position entry.

  run _order_windows_by_position "$TMP/windows" "$TMP/positions"
  order="$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')"
  [ "$order" = "300 100 200 " ]
}

@test "_order_windows_by_position preserves relative order among multiple unpositioned windows" {
  printf '1\t100\tkitty\ttiling\n' >"$TMP/windows"
  printf '1\t200\tSlack\ttiling\n' >>"$TMP/windows"
  printf '1\t300\tGoogle Chrome\ttiling\n' >>"$TMP/windows"
  : >"$TMP/positions"

  run _order_windows_by_position "$TMP/windows" "$TMP/positions"
  order="$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')"
  [ "$order" = "100 200 300 " ]
}

@test "_order_windows_by_position keeps workspaces grouped, not interleaved" {
  # Interleaved input across two workspaces; x-positions would otherwise mix them.
  printf '1\t100\tkitty\ttiling\n' >"$TMP/windows"
  printf '2\t200\tSlack\ttiling\n' >>"$TMP/windows"
  printf '1\t101\tGoogle Chrome\ttiling\n' >>"$TMP/windows"
  printf '2\t201\tFirefox\ttiling\n' >>"$TMP/windows"
  printf '100\t50\t0\n' >"$TMP/positions"
  printf '101\t10\t0\n' >>"$TMP/positions"
  printf '200\t5\t0\n' >>"$TMP/positions"
  printf '201\t1\t0\n' >>"$TMP/positions"

  run _order_windows_by_position "$TMP/windows" "$TMP/positions"
  ws_order="$(printf '%s\n' "$output" | cut -f1 | uniq | tr '\n' ' ')"
  [ "$ws_order" = "1 2 " ]
  ws1_order="$(printf '%s\n' "$output" | awk -F'\t' '$1=="1"{print $2}' | tr '\n' ' ')"
  [ "$ws1_order" = "101 100 " ]
  ws2_order="$(printf '%s\n' "$output" | awk -F'\t' '$1=="2"{print $2}' | tr '\n' ' ')"
  [ "$ws2_order" = "201 200 " ]
}

@test "_order_windows_by_position with an empty positions file returns the original order unchanged (graceful fallback)" {
  printf '1\t300\tSlack\ttiling\n' >"$TMP/windows"
  printf '1\t100\tkitty\ttiling\n' >>"$TMP/windows"
  printf '1\t200\tGoogle Chrome\ttiling\n' >>"$TMP/windows"
  : >"$TMP/positions"

  run _order_windows_by_position "$TMP/windows" "$TMP/positions"
  [ "$status" -eq 0 ]
  order="$(printf '%s\n' "$output" | cut -f2 | tr '\n' ' ')"
  [ "$order" = "300 100 200 " ]
}

@test "_order_windows_by_position keeps a window's app-name and layout columns intact" {
  printf '1\t300\tGoogle Chrome\tfloating\n' >"$TMP/windows"
  printf '1\t100\tkitty\ttiling\n' >>"$TMP/windows"
  printf '100\t10\t0\n' >"$TMP/positions"
  printf '300\t20\t0\n' >>"$TMP/positions"

  run _order_windows_by_position "$TMP/windows" "$TMP/positions"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF $'1\t100\tkitty\ttiling'
  echo "$output" | grep -qxF $'1\t300\tGoogle Chrome\tfloating'
}

# --- _stabilize_hidden_order (TASK-58) ----------------------------------------
# AeroSpace stashes a hidden workspace's windows at one off-screen point, so
# position ordering is meaningless for them. Hidden workspaces keep the order
# cached when they were last visible; a visible workspace only refreshes the
# cache when its positions genuinely resolved this pass (round 2: not when
# every window reports the identical parked coordinate, and not when the
# positions lookup came back empty for it - see _ws_resolved_workspaces).
# workspaces tsv columns: workspace, monitor, focused, visible.
# positions tsv columns: window-id, x, y (optional 4th arg; omitted/empty
# means every workspace is unresolved, the same as a failed osascript call).

@test "_stabilize_hidden_order re-sorts a hidden workspace's rows to the cached order" {
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >"$TMP/windows"    # aerospace order: Teams first
  printf '8\t9185\tSlack\ttiling\n' >>"$TMP/windows"
  printf '8\tDELL\tfalse\tfalse\n' >"$TMP/workspaces"             # ws 8 hidden
  printf '8\t9185\n8\t31303\n' >"$TMP/cache"                      # last-visible order: Slack, Teams
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'8\t9185\tSlack\ttiling' ]
  [ "${lines[1]}" = $'8\t31303\tMicrosoft Teams\ttiling' ]
}

@test "_stabilize_hidden_order leaves a visible+resolved workspace's order alone and refreshes its cache" {
  printf '8\t9185\tSlack\ttiling\n' >"$TMP/windows"
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >>"$TMP/windows"
  printf '8\tDELL\ttrue\ttrue\n' >"$TMP/workspaces"               # ws 8 visible
  printf '8\t31303\n8\t9185\n' >"$TMP/cache"                      # stale cache, must be replaced
  printf '9185\t10\t0\n31303\t20\t0\n' >"$TMP/positions"          # distinct positions: resolved
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache" "$TMP/positions"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'8\t9185\tSlack\ttiling' ]
  [ "${lines[1]}" = $'8\t31303\tMicrosoft Teams\ttiling' ]
  run cat "$TMP/cache"
  [ "${lines[0]}" = $'8\t9185' ]
  [ "${lines[1]}" = $'8\t31303' ]
}

@test "_stabilize_hidden_order keeps a hidden workspace's cache rows intact" {
  printf '8\t9185\tSlack\ttiling\n' >"$TMP/windows"
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >>"$TMP/windows"   # both windows still open (live)
  printf '8\tDELL\tfalse\tfalse\n' >"$TMP/workspaces"
  printf '8\t9185\n8\t31303\n' >"$TMP/cache"
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache"
  [ "$status" -eq 0 ]
  run cat "$TMP/cache"
  [ "${lines[0]}" = $'8\t9185' ]
  [ "${lines[1]}" = $'8\t31303' ]
}

@test "_stabilize_hidden_order appends unknown windows after the cached ones, in current order" {
  printf '8\t500\tNew App\ttiling\n' >"$TMP/windows"               # not in cache
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >>"$TMP/windows"
  printf '8\t9185\tSlack\ttiling\n' >>"$TMP/windows"
  printf '8\tDELL\tfalse\tfalse\n' >"$TMP/workspaces"
  printf '8\t9185\n8\t31303\n' >"$TMP/cache"
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'8\t9185\tSlack\ttiling' ]
  [ "${lines[1]}" = $'8\t31303\tMicrosoft Teams\ttiling' ]
  [ "${lines[2]}" = $'8\t500\tNew App\ttiling' ]
}

@test "_stabilize_hidden_order with an empty cache and tied/no positions falls back to ascending window-id order, not the input list order" {
  # TASK-58 round 2: this is the diagnosed failure - no cache yet (fresh
  # restart) and no position data resolved for this workspace. The old
  # behavior passed the (unstable, aerospace-list-order) input through
  # unchanged; the fix is a deterministic tiebreak instead.
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >"$TMP/windows"     # aerospace order: Teams, then Slack
  printf '8\t9185\tSlack\ttiling\n' >>"$TMP/windows"
  printf '8\tDELL\tfalse\tfalse\n' >"$TMP/workspaces"
  : >"$TMP/cache"
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'8\t9185\tSlack\ttiling' ]                    # ascending wid: 9185 before 31303
  [ "${lines[1]}" = $'8\t31303\tMicrosoft Teams\ttiling' ]
}

@test "_stabilize_hidden_order handles mixed visible and hidden workspaces and keeps grouping" {
  printf '10\t100\tGhostty\ttiling\n' >"$TMP/windows"
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >>"$TMP/windows"
  printf '8\t9185\tSlack\ttiling\n' >>"$TMP/windows"
  printf '10\tDELL\ttrue\ttrue\n' >"$TMP/workspaces"
  printf '8\tDELL\tfalse\tfalse\n' >>"$TMP/workspaces"
  printf '8\t9185\n8\t31303\n' >"$TMP/cache"
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'10\t100\tGhostty\ttiling' ]
  [ "${lines[1]}" = $'8\t9185\tSlack\ttiling' ]
  [ "${lines[2]}" = $'8\t31303\tMicrosoft Teams\ttiling' ]
}

# --- TASK-58 round 2: capture hardening + persistence + pruning + atomicity --

@test "_stabilize_hidden_order does NOT overwrite an existing cached order when this pass's positions are all tied" {
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >"$TMP/windows"     # visible, but all parked at one point
  printf '8\t9185\tSlack\ttiling\n' >>"$TMP/windows"
  printf '8\tDELL\ttrue\ttrue\n' >"$TMP/workspaces"                # ws 8 visible
  printf '8\t9185\n8\t31303\n' >"$TMP/cache"                       # existing frozen order: Slack, Teams
  printf '9185\t2407\t976\n31303\t2407\t976\n' >"$TMP/positions"   # identical parked coordinate: tied
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache" "$TMP/positions"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'8\t9185\tSlack\ttiling' ]                    # cached order wins, not tied input order
  [ "${lines[1]}" = $'8\t31303\tMicrosoft Teams\ttiling' ]
  run cat "$TMP/cache"
  [ "${lines[0]}" = $'8\t9185' ]                                   # cache untouched by the tied pass
  [ "${lines[1]}" = $'8\t31303' ]
}

@test "_stabilize_hidden_order does NOT overwrite an existing cached order when the positions lookup came back empty" {
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >"$TMP/windows"
  printf '8\t9185\tSlack\ttiling\n' >>"$TMP/windows"
  printf '8\tDELL\ttrue\ttrue\n' >"$TMP/workspaces"
  printf '8\t9185\n8\t31303\n' >"$TMP/cache"
  : >"$TMP/positions"                                              # empty lookup for this pass
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache" "$TMP/positions"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'8\t9185\tSlack\ttiling' ]
  [ "${lines[1]}" = $'8\t31303\tMicrosoft Teams\ttiling' ]
  run cat "$TMP/cache"
  [ "${lines[0]}" = $'8\t9185' ]
  [ "${lines[1]}" = $'8\t31303' ]
}

@test "_stabilize_hidden_order prunes dead window-ids and vanished workspaces from the cache on write" {
  # ws 8 is now visible+resolved (refreshes and prunes to its live windows);
  # ws 9 no longer exists at all - its whole cache entry must be dropped.
  printf '8\t9185\tSlack\ttiling\n' >"$TMP/windows"                # 31303 (Teams) closed - no longer live
  printf '8\tDELL\ttrue\ttrue\n' >"$TMP/workspaces"
  printf '8\t9185\n8\t31303\n9\t777\n' >"$TMP/cache"                # 31303 dead, ws 9 gone entirely
  printf '9185\t10\t0\n' >"$TMP/positions"
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache" "$TMP/positions"
  [ "$status" -eq 0 ]
  run cat "$TMP/cache"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = $'8\t9185' ]
}

@test "_stabilize_hidden_order writes the cache via a temp file + rename, not in place" {
  printf '8\t9185\tSlack\ttiling\n' >"$TMP/windows"
  printf '8\tDELL\ttrue\ttrue\n' >"$TMP/workspaces"
  : >"$TMP/cache"
  printf '9185\t10\t0\n' >"$TMP/positions"
  # A stale sibling temp file from a torn-write elsewhere in this directory
  # must never survive as (or leak into) the real cache path.
  : >"$TMP/cache.tmp.999999"
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$TMP/cache" "$TMP/positions"
  [ "$status" -eq 0 ]
  [ -e "$TMP/cache" ]
  run cat "$TMP/cache"
  [ "${lines[0]}" = $'8\t9185' ]
  # This run's own tempfile (cache.tmp.$$) must have been renamed away, not
  # left behind - only the pre-existing unrelated stale one remains.
  local leftover
  leftover="$(find "$TMP" -maxdepth 1 -name 'cache.tmp.*' ! -name 'cache.tmp.999999')"
  [ -z "$leftover" ]
}

@test "the persistent order cache survives a simulated plugin restart" {
  # First "run": populate the persistent cache the way _run_reconcile_pass
  # does (visible+resolved workspace, real distinct positions).
  printf '8\t9185\tSlack\ttiling\n' >"$TMP/windows"
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >>"$TMP/windows"
  printf '8\tDELL\ttrue\ttrue\n' >"$TMP/workspaces"
  local persist="$TMP/persistent_ws_order"
  : >"$persist"
  printf '9185\t10\t0\n31303\t20\t0\n' >"$TMP/positions"
  _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$persist" "$TMP/positions" >/dev/null

  # "Restart": a fresh invocation with ws 8 now hidden and parked (tied), no
  # in-memory state carried over - only $persist on disk, exactly as main()
  # re-points ORDER_CACHE_FILE at the same disk path after a relaunch.
  printf '8\t31303\tMicrosoft Teams\ttiling\n' >"$TMP/windows2"     # aerospace order flipped
  printf '8\t9185\tSlack\ttiling\n' >>"$TMP/windows2"
  printf '8\tDELL\tfalse\tfalse\n' >"$TMP/workspaces2"
  printf '9185\t2407\t976\n31303\t2407\t976\n' >"$TMP/positions2"   # parked: tied
  run _stabilize_hidden_order "$TMP/windows2" "$TMP/workspaces2" "$persist" "$TMP/positions2"
  [ "$status" -eq 0 ]
  # The persisted last-visible order (Slack, Teams) replays after the restart.
  [ "${lines[0]}" = $'8\t9185\tSlack\ttiling' ]
  [ "${lines[1]}" = $'8\t31303\tMicrosoft Teams\ttiling' ]
}

# --- _setup_order_cache (TASK-58 round 2 review hardening) -------------------

@test "_setup_order_cache falls back to a session-only cache and logs when the persistent dir is not writable" {
  local dir="$TMP/nowrite"
  mkdir -p "$dir"
  chmod 555 "$dir"
  ORDER_CACHE_IS_FALLBACK=0
  ORDER_CACHE_FILE=""
  _setup_order_cache "$dir" 2>"$TMP/stderr"
  [ "$ORDER_CACHE_IS_FALLBACK" = "1" ]
  [ -n "$ORDER_CACHE_FILE" ]
  [ -e "$ORDER_CACHE_FILE" ]
  case "$ORDER_CACHE_FILE" in "$dir"/*) false ;; *) true ;; esac  # not inside the unwritable dir
  run cat "$TMP/stderr"
  [[ "$output" == *"not writable"* ]]

  # The fallback still lets hidden-workspace order freezing work end to end.
  printf '8\t9185\tSlack\ttiling\n' >"$TMP/windows"
  printf '8\tDELL\tfalse\tfalse\n' >"$TMP/workspaces"
  printf '8\t9185\n' >"$ORDER_CACHE_FILE"
  run _stabilize_hidden_order "$TMP/windows" "$TMP/workspaces" "$ORDER_CACHE_FILE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'8\t9185\tSlack\ttiling' ]

  rm -f "$ORDER_CACHE_FILE"
  chmod 755 "$dir"                         # restore so bats teardown can clean $TMP
}

@test "_setup_order_cache removes stale ws_order.tmp.* siblings on startup" {
  local dir="$TMP/cachedir"
  mkdir -p "$dir"
  : >"$dir/ws_order.tmp.12345"
  : >"$dir/ws_order.tmp.6789"
  printf '1\t100\n' >"$dir/ws_order"       # the real cache, must NOT be touched
  ORDER_CACHE_IS_FALLBACK=1
  ORDER_CACHE_FILE=""
  _setup_order_cache "$dir"
  [ "$ORDER_CACHE_IS_FALLBACK" = "0" ]
  [ "$ORDER_CACHE_FILE" = "$dir/ws_order" ]
  run cat "$dir/ws_order"
  [ "${lines[0]}" = $'1\t100' ]
  local leftover
  leftover="$(find "$dir" -maxdepth 1 -name 'ws_order.tmp.*')"
  [ -z "$leftover" ]
}

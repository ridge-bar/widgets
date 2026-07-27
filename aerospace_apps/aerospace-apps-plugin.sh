#!/usr/bin/env bash
# Ridge AeroSpace Apps plugin: a center window/app list for the focused
# workspace on each monitor, driven by `aerospace subscribe`. Launched and
# supervised by Ridge; talks to ridge over $RIDGE_SOCKET via the `ridge` CLI.
# Split from the former combined `aerospace` plugin: this half owns only the
# per-window icon+label bubbles. The workspace pills (and the "AeroSpace
# down" status warning) are the sibling `aerospace_workspaces` plugin. See
# README.md.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The main plugin process. The subscribe pipeline's while-loop runs in a
# subshell that survives as a ppid-1 orphan if the main process is killed
# hard (no signal reaches the pipeline); an orphan that kept reconciling
# would fight the supervisor's replacement instance over the same items.
# _on_subscribe_event checks this pid and exits the loop when it is gone.
MAIN_PID=$$
# shellcheck source=glyphs.sh disable=SC1091
source "${PLUGIN_ROOT}/glyphs.sh"

sanitize() {
  local s="$1"
  printf '%s' "${s//[^A-Za-z0-9_-]/_}"
}

# Window-position cache (run_reconcile): the osascript position query is the
# slowest reconcile step (~100ms), so when the window snapshot is unchanged
# the previous map is reused - at most once in a row, so a window moved
# without any window-set change re-sorts one pass later, never goes stale
# indefinitely.
LAST_WINDOWS_SIG=""
POS_REUSED=0
POS_CACHE_FILE=""

# Window-focus fast path: the window the fast path last highlighted, and the
# reconcile-persisted map from window-id to center-list item id (the items
# have positional ids, so only the reconcile knows which pill a window owns).
# The map is a snapshot of the LAST reconcile, not a stable keyspace: when the
# same event also closes/reorders windows, a lookup can hit a pill the next
# pass reassigns - bounded to one sub-frame, since the reconcile runs
# synchronously right after the fast path.
LAST_FOCUSED_WIN=""
WIN_MAP_FILE=""

# Click staleness map: id -> click command applied as of the last reconcile
# pass. Positional ids (aerospace_apps.<mon>.<index>.*) can keep the same id
# while the click that belongs at that id changes underneath it -
# current_state has no click column to diff against, so reconcile() reads
# this file to detect the drift itself. Overwritten wholesale from
# desired_state's output every pass (same pattern as WIN_MAP_FILE above), so
# removed ids fall out for free.
CLICK_MAP_FILE=""

# Last-visible window order per workspace (ws\twid rows), maintained by
# _stabilize_hidden_order. Only the visible workspace's windows are ever
# rendered by this plugin, but the ordering helper processes every
# workspace's rows uniformly (see aerospace_workspaces' identical copy of
# this function for the hidden-workspace rationale); main() points this at a
# persistent path under XDG_CACHE_HOME so a restart mid-session doesn't
# perturb ordering. Tests that source this script without calling main() get
# a lazy mktemp fallback in _run_reconcile_pass instead.
ORDER_CACHE_FILE=""
# 1 when ORDER_CACHE_FILE is a session-only mktemp fallback (the persistent
# cache dir was not writable), so main()'s EXIT trap knows to clean it up
# instead of leaving it behind. 0 when ORDER_CACHE_FILE is the real
# persistent path and must survive process exit.
ORDER_CACHE_IS_FALLBACK=0

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this plugin's
# own eval; the click's window-id must survive both.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# --font/--font-style/--font-size flags for an app-glyph item (app_icon's
# ligature only renders as an icon in the sketchybar-app-font font, not the
# bar's default font). Each value is %q-quoted: this is assembled into a line
# reconcile emits for run_reconcile's eval. Empty SETTING_app_font omits the
# flags entirely (load_settings normally guarantees it is non-empty, but a
# caller setting it directly - e.g. a test - can still disable it this way).
_app_font_flags() {
  [[ -z "$SETTING_app_font" ]] && return 0
  local qaf qas; printf -v qaf '%q' "$SETTING_app_font"; printf -v qas '%q' "$SETTING_app_font_style"
  printf ' --font %s --font-style %s' "$qaf" "$qas"
  if [[ -n "$SETTING_app_font_size" ]]; then
    local qasz; printf -v qasz '%q' "$SETTING_app_font_size"
    printf ' --font-size %s' "$qasz"
  fi
}

# --bg-corner-radius flag for a bracket add/set line: %q-quoted for the eval
# layer, same discipline as _app_font_flags. Empty (the user never set
# window_corner_radius) omits the flag entirely so ridge core's global
# bar.item_corner_radius default takes effect.
_cr_flag() {
  local cr="$1"
  [[ -z "$cr" ]] && return 0
  local q; printf -v q '%q' "$cr"
  printf ' --bg-corner-radius %s' "$q"
}

# --bg-height flag for a bracket add/set line: same %q-quoting discipline as
# _cr_flag. Empty (the user never set height) omits the flag entirely so
# ridge core's global bar.item_height default takes effect.
_height_flag() {
  local h="$1"
  [[ -z "$h" ]] && return 0
  local q; printf -v q '%q' "$h"
  printf ' --bg-height %s' "$q"
}

# shellcheck disable=SC2034 # SETTING_* are consumed by main() and reconcile(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  # Region for the center window-list widget.
  SETTING_region="$(jq -r '.region // "center"' <<<"$json")"
  # Font for app-glyph ligatures (sketchybar-app-font, or a compatible icon
  # font); these only resolve to icon glyphs in a font that defines the
  # ligatures. Empty -> app icons render as literal ":app_name:" text.
  SETTING_app_font="$(jq -r '.app_font // "sketchybar-app-font"' <<<"$json")"
  [[ -n "$SETTING_app_font" ]] || SETTING_app_font="sketchybar-app-font"
  SETTING_app_font_style="$(jq -r '.app_font_style // "Regular"' <<<"$json")"
  [[ -n "$SETTING_app_font_style" ]] || SETTING_app_font_style="Regular"
  SETTING_app_font_size="$(jq -r '.app_font_size // "14"' <<<"$json")"
  [[ "$SETTING_app_font_size" =~ ^[0-9]*\.?[0-9]+$ ]] || SETTING_app_font_size="14"
  SETTING_glyph_color="$(jq -r '.glyph_color // "theme:secondary"' <<<"$json")"
  SETTING_glyph_focused_color="$(jq -r '.glyph_focused_color // "theme:primary"' <<<"$json")"
  # Bubble bg is a constant color (focus is shown by a border, not a bg swap).
  SETTING_bg_color="$(jq -r '.bg_color // "theme:background"' <<<"$json")"
  SETTING_border_focused_color="$(jq -r '.border_focused_color // "theme:system"' <<<"$json")"
  SETTING_border_width="$(jq -r '.border_width // "2"' <<<"$json")"
  SETTING_corner_radius="$(jq -r '.corner_radius // ""' <<<"$json")"
  SETTING_height="$(jq -r '.height // ""' <<<"$json")"
  SETTING_pad_left="$(jq -r '.pad_left // "8"' <<<"$json")"
  SETTING_pad_right="$(jq -r '.pad_right // "8"' <<<"$json")"
  # Gap between adjacent app bubbles (bracket margin). Matches the workspace
  # pills' bubble_margin so the two strips read as one system.
  SETTING_bubble_margin="$(jq -r '.bubble_margin // "6"' <<<"$json")"
  # Bar font for the app-NAME label text (the icon glyph uses app_font). Empty
  # inherits the bar's global default font.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  # Max windows drawn in the center list (per monitor); non-numeric -> 8.
  SETTING_max="$(jq -r '.max // "8"' <<<"$json")"
  [[ "$SETTING_max" =~ ^[0-9]+$ ]] || SETTING_max="8"
  # Update strategy: "subscribe" (default, aerospace subscribe stream), "trigger"
  # (reconcile on `ridge trigger aerospace_apps`), or "poll" (interval). Unknown -> subscribe.
  SETTING_update_mode="$(jq -r '.update_mode // "subscribe"' <<<"$json")"
  case "$SETTING_update_mode" in subscribe|trigger|poll) ;; *) SETTING_update_mode="subscribe" ;; esac
  # Poll interval in seconds (poll mode only). Must be a positive number, else
  # default 2 - a zero-equivalent (0, 00, .0, 0.00) would make `sleep` return
  # instantly and turn poll mode into a CPU-hammering tight loop. Stripping all
  # dots and zeros leaves nothing iff the value is zero-equivalent.
  SETTING_poll_interval="$(jq -r '.poll_interval // "2"' <<<"$json")"
  [[ "$SETTING_poll_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_poll_interval//[.0]/}" ]] || SETTING_poll_interval="2"
}

desired_state() {
  # shellcheck disable=SC2034 # monitors_tsv kept for interface parity; monitor display name comes from workspaces_tsv
  local monitors_tsv="$1" workspaces_tsv="$2" windows_tsv="$3" focused_win="$4"
  local ws monitor focused visible monSan wi w wid wapp wlayout wcol wname wclick wbase

  # Per monitor, the windows on the workspace VISIBLE on that monitor, one
  # bubble (app icon + name) each, capped at max, display-targeted to that
  # monitor. The focused window's bubble gets a border; a floating window's
  # name gets a pin glyph. Clicking focuses the window. windows_tsv columns:
  # workspace, window-id, app-name, window-layout.
  # shellcheck disable=SC2034 # focused is read only to keep it out of the visible field
  while IFS=$'\t' read -r ws monitor focused visible; do
    [[ -z "$ws" ]] && continue
    [[ "$visible" == "true" ]] || continue
    monSan="$(sanitize "$monitor")"
    wi=0
    while IFS=$'\t' read -r w wid wapp wlayout; do
      [[ "$w" != "$ws" ]] && continue
      [[ -z "$wid" || -z "$wapp" ]] && continue
      wi=$((wi + 1))
      [[ "$wi" -gt "$SETTING_max" ]] && break
      wbase="aerospace_apps.${monSan}.${wi}"
      wcol="$SETTING_glyph_color"
      [[ -n "$focused_win" && "$wid" == "$focused_win" ]] && wcol="$SETTING_glyph_focused_color"
      # Single-quote the raw window-id for the sh -c layer ridge core runs the click on.
      wclick="aerospace focus --window-id $(shq "$wid")"
      # Icon item: app-font ligature (reconcile adds the app-font flags).
      printf 'ITEM\t%s.icon\t%s\t%s\t%s\t%s\t%s\n' \
        "$wbase" "$monitor" "$monitor" "$(app_icon "$wapp")" "$wcol" "$wclick"
      # Label item: app name, plus a pin glyph for a floating ("pinned") window.
      wname="$wapp"; [[ "$wlayout" == "floating" ]] && wname="$wapp 󰐃"
      printf 'ITEM\t%s.label\t%s\t%s\t%s\t%s\t%s\n' \
        "$wbase" "$monitor" "$monitor" "$wname" "$wcol" "$wclick"
      # Bracket: constant window bg, no static border - focus is shown by the
      # bar's animated selection indicator following the highlighted icon.
      printf 'BRACKET\t%s\t%s.icon,%s.label\t%s\t%s\t%s\n' \
        "$wbase" "$wbase" "$wbase" "$SETTING_bg_color" "$SETTING_bg_color" "0"
      if [[ -n "$focused_win" && "$wid" == "$focused_win" ]]; then printf 'HL\t%s.icon\ton\n' "$wbase"; else printf 'HL\t%s.icon\toff\n' "$wbase"; fi
      # Window-id -> item-id map row for the window-focus fast path. reconcile()
      # ignores unknown tags; run_reconcile persists these into WIN_MAP_FILE.
      printf 'WMAP\t%s\t%s.icon\n' "$wid" "$wbase"
    done <"$windows_tsv"
  done <"$workspaces_tsv"
}

current_state() {
  local items_json="$1" brackets_json="$2"
  # Leaf items: center window-list items (aerospace_apps.*). `ridge query`
  # exposes only text + color (not display/monitor/click), so those columns
  # are empty; reconcile diffs on text + color, the fields that round-trip.
  jq -r '
    .[] | select(.id | startswith("aerospace_apps."))
    | "ITEM\t\(.id)\t\t\t\(.text)\t\(.color)\t"
  ' "$items_json"
  # Brackets. `query brackets` has no bg-color, so the bg column is empty;
  # reconcile then always re-applies the desired bg.
  jq -r '
    .[] | select(.id | startswith("aerospace_apps."))
    | "BRACKET\t\(.id)\t\(.members | join(","))\t"
  ' "$brackets_json"
}

# Sort-key columns for an item id, used by reconcile to order the strip:
#   <mon>\t<idx>\t<kind>\t0
_item_sortkey() {
  local id="$1" rest kind
  rest="${id#aerospace_apps.}"   # <monSan>.<i>.icon|label
  local mon r2 wi
  mon="${rest%%.*}"
  r2="${rest#*.}"
  wi="${r2%%.*}"
  case "$id" in
    *.icon)  kind=0;;
    *.label) kind=1;;
    *)       kind=2;;
  esac
  printf '%s\t%s\t%s\t%s' "$mon" "$wi" "$kind" "0"
}

reconcile() {
  # click_map_file (3rd arg, optional): id -> click command this item was last
  # painted with, persisted by _run_reconcile_pass across passes. Ids are
  # POSITIONAL (aerospace_apps.<mon>.<index>), not content-keyed, so
  # current_state (from `ridge query items`, no click column) can never see a
  # click go stale on its own - a reused pill whose underlying window-id
  # changed (close/reopen, reorder, or two windows of the same app swapping
  # position) would otherwise keep firing its old --window-id forever. When
  # the map is provided, an id WITHOUT a record has an unknown applied click
  # and gets one corrective set (covers plugin restarts and stores painted by
  # older versions). Omitting the arg entirely (legacy fixtures) keeps
  # reconcile click-set-free.
  local desired_file="$1" current_file="$2" click_map_file="${3:-}"
  declare -A d_display=() d_text=() d_color=() d_click=() d_bmem=() d_bbg=() d_bbc=() d_bbw=() d_hl=() \
             c_text=() c_color=() c_bmem=() c_bbg=() c_click=()
  local tag a b c d e f line c_seq=""

  if [[ -n "$click_map_file" && -f "$click_map_file" ]]; then
    while IFS=$'\t' read -r a f || [[ -n "$a" ]]; do
      [[ -z "$a" ]] && continue
      c_click[$a]="$f"
    done <"$click_map_file"
  fi

  # Tab is an IFS-whitespace char, so `IFS=$'\t' read` collapses consecutive
  # tabs and drops empty fields (current-state ITEM lines have them).
  # Swap tabs for a control byte that isn't whitespace-class before splitting.
  while IFS= read -r line || [[ -n "$line" ]]; do
    IFS=$'\x01' read -r tag a b c d e f <<<"${line//$'\t'/$'\x01'}"
    case "$tag" in
      ITEM) d_display[$a]="$b"; d_text[$a]="$d"; d_color[$a]="$e"; d_click[$a]="$f";;
      BRACKET) d_bmem[$a]="$b"; d_bbg[$a]="$c"; d_bbc[$a]="$d"; d_bbw[$a]="$e";;
      HL) d_hl[$a]="$b";;
    esac
  done <"$desired_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    IFS=$'\x01' read -r tag a b c d e f <<<"${line//$'\t'/$'\x01'}"
    case "$tag" in
      # c_seq records the current render order (ridge query returns items in
      # store/add order), used to detect when items need reordering.
      ITEM) c_text[$a]="$d"; c_color[$a]="$e"; c_seq="${c_seq}${a}"$'\n';;
      BRACKET) c_bmem[$a]="$b"; c_bbg[$a]="$c";;
    esac
  done <"$current_file"

  local id
  local d_seq
  d_seq="$(for id in "${!d_text[@]}"; do
             printf '%s\t%s\n' "$(_item_sortkey "$id")" "$id"
           done | sort -t$'\t' -k1,1V -k2,2n -k3,3n -k4,4n | cut -f5)"
  # Incremental ordered reconcile: insert new items at their position, move only
  # genuinely-reordered items, set changed content. No whole-strip rebuild.
  # ItemStore renders in store order; --before/--after position an insert and
  # `ridge move` repositions.
  local first_current
  first_current="$(printf '%s' "$c_seq" | head -n1)"
  local cur_common des_common
  cur_common="$(printf '%s' "$c_seq" | while IFS= read -r cid; do [[ -z "$cid" ]] && continue; [[ -n "${d_text[$cid]+set}" ]] && printf '%s\n' "$cid"; done)"
  des_common="$(printf '%s\n' "$d_seq" | while IFS= read -r did; do [[ -z "$did" ]] && continue; [[ -n "${c_text[$did]+set}" ]] && printf '%s\n' "$did"; done)"
  local reorder=0
  [[ "$cur_common" != "$des_common" ]] && reorder=1

  local prev=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    local pad=""
    case "$id" in
      *.icon)  local qpl; printf -v qpl '%q' "$SETTING_pad_left"; pad=" --padding-left $qpl --padding-right 4" ;;
      *.label) local qpr; printf -v qpr '%q' "$SETTING_pad_right"; pad=" --padding-left 4 --padding-right $qpr" ;;
    esac
    # anchor: place this id after the previous desired id (or before the current
    # first item when it is the first desired id). ids are plugin-generated, but
    # %q-quote for the eval layer regardless.
    local anchor=""
    if [[ -n "$prev" ]]; then
      local qprev; printf -v qprev '%q' "$prev"; anchor=" --after $qprev"
    elif [[ -n "$first_current" ]]; then
      local qfirst; printf -v qfirst '%q' "$first_current"; anchor=" --before $qfirst"
    fi
    if [[ -z "${c_text[$id]+set}" ]]; then
      # INSERT a new item at its position. The icon renders its ligature in
      # the app-icon font; the label item keeps the bar font.
      local extra=""
      case "$id" in
        *.icon) extra="$(_app_font_flags)" ;;
        *.label) [[ -n "$SETTING_font" ]] && { local qf; printf -v qf '%q' "$SETTING_font"; extra=" --font $qf"; } ;;
      esac
      printf 'ridge add %s --region %q --display %q --text %q --color %q --click %q%s%s%s\n' \
        "$id" "$SETTING_region" "${d_display[$id]}" "${d_text[$id]}" \
        "${d_color[$id]}" "${d_click[$id]}" "$extra" "$pad" "$anchor"
    else
      # existing item: reposition only on a genuine reorder, and re-set content
      # (text/color/padding) when it changed.
      [[ "$reorder" == "1" ]] && printf 'ridge move %s%s\n' "$id" "$anchor"
      if [[ "${d_text[$id]}" != "${c_text[$id]}" || "${d_color[$id]}" != "${c_color[$id]}" ]]; then
        printf 'ridge set %s --text %q --color %q%s\n' "$id" "${d_text[$id]}" "${d_color[$id]}" "$pad"
      fi
      # Click staleness: with a click map in play, an id with no record (cold
      # start after a restart, or a store painted by an older plugin) has an
      # UNKNOWN - possibly stale - applied click, so it gets one corrective
      # set too. Without the map arg (legacy callers/fixtures) clicks are
      # left alone entirely.
      if [[ -n "$click_map_file" && -n "${d_click[$id]}" && "${d_click[$id]}" != "${c_click[$id]:-}" ]]; then
        printf 'ridge set %s --click %q\n' "$id" "${d_click[$id]}"
      fi
    fi
    prev="$id"
  done <<<"$d_seq"
  # Stale leaf items: present now, not desired -> remove.
  for id in "${!c_text[@]}"; do
    [[ -z "${d_text[$id]+set}" ]] && printf 'ridge remove %s\n' "$id"
  done
  # Brackets: the border changes on focus (bg stays constant), so set carries
  # bg/border plus the bubble radius/height. `query brackets` returns no
  # bg/border, so the current bg column (c_bbg) is always empty and differs
  # from desired, forcing a re-set every reconcile pass regardless of focus.
  for id in "${!d_bmem[@]}"; do
    local cr_flag; cr_flag="$(_cr_flag "$SETTING_corner_radius")"
    local height_flag; height_flag="$(_height_flag "$SETTING_height")"
    local qm; printf -v qm '%q' "$SETTING_bubble_margin"
    if [[ -z "${c_bmem[$id]+set}" ]]; then
      printf 'ridge bracket add %s --members %s --bg-color %q%s%s --margin %s --border-color %q --border-width %q\n' \
        "$id" "${d_bmem[$id]}" "${d_bbg[$id]}" "$cr_flag" "$height_flag" "$qm" "${d_bbc[$id]}" "${d_bbw[$id]}"
    elif [[ "${d_bmem[$id]}" != "${c_bmem[$id]}" || "${d_bbg[$id]}" != "${c_bbg[$id]}" ]]; then
      printf 'ridge bracket set %s --members %s --bg-color %q%s%s --margin %s --border-color %q --border-width %q\n' \
        "$id" "${d_bmem[$id]}" "${d_bbg[$id]}" "$cr_flag" "$height_flag" "$qm" "${d_bbc[$id]}" "${d_bbw[$id]}"
    fi
  done
  for id in "${!c_bmem[@]}"; do
    [[ -z "${d_bmem[$id]+set}" ]] && printf 'ridge bracket remove %s\n' "$id"
  done
  # Highlight AFTER items and brackets exist, so the bar's animated selection
  # indicator wraps the complete bubble the moment the highlight lands.
  # Idempotent on the bar side (updateHighlight no-ops when unchanged).
  for id in "${!d_hl[@]}"; do
    printf 'ridge set %s --highlight %s\n' "$id" "${d_hl[$id]}"
  done
  return 0
}

# AeroSpace's list-windows order is not the visual on-screen order and is not
# stable (see window_positions.js). Reorders windows_tsv so that WITHIN each
# workspace, rows are sorted by ascending on-screen x, then y; a window absent
# from positions_tsv (no position data) sorts last, stably. Workspaces stay
# grouped in their order of first appearance - never interleaved. Output keeps
# the same columns (workspace, window-id, app-name, window-layout); only row
# order within a workspace changes.
#
# Known limitation: accordion-layout windows overlap/cascade on screen, so an
# x-sort is not meaningful for them. No special accordion handling here.
_order_windows_by_position() {
  local windows_tsv="$1" positions_tsv="$2"
  awk -F'\t' -v OFS='\t' -v posfile="$positions_tsv" '
    FILENAME == posfile {
      pos_x[$1] = $2; pos_y[$1] = $3; has[$1] = 1
      next
    }
    {
      ws = $1; wid = $2
      if (!(ws in gorder)) { gorder[ws] = ++gseq }
      n++
      x = (wid in has) ? pos_x[wid] : 1000000000
      y = (wid in has) ? pos_y[wid] : 0
      printf "%d\t%d\t%d\t%d\t%s\n", gorder[ws], x, y, n, $0
    }
  ' "$positions_tsv" "$windows_tsv" \
    | sort -t $'\t' -k1,1n -k2,2n -k3,3n -k4,4n \
    | cut -f5-
}

# Same idea as aerospace_workspaces' fast path, for the center window list on
# app/window switches: one cheap focused-window query, then move the
# highlight via the reconcile-persisted window-id -> item-id map. A window
# the map does not know (new window, or no reconcile yet) is left to the full
# reconcile - LAST_FOCUSED_WIN is not advanced, so the next known focus still
# unhighlights the right pill.
_fast_path_window_focus() {
  [[ -n "$WIN_MAP_FILE" && -s "$WIN_MAP_FILE" ]] || return 0
  local wid
  wid="$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null | head -1)"
  [[ -n "$wid" && "$wid" != "$LAST_FOCUSED_WIN" ]] || return 0
  local new_item old_item
  new_item="$(awk -F'\t' -v w="$wid" '$1 == w { print $2; exit }' "$WIN_MAP_FILE")"
  [[ -n "$new_item" ]] || return 0
  if [[ -n "$LAST_FOCUSED_WIN" ]]; then
    old_item="$(awk -F'\t' -v w="$LAST_FOCUSED_WIN" '$1 == w { print $2; exit }' "$WIN_MAP_FILE")"
    [[ -n "$old_item" ]] && { ridge set "$old_item" --highlight off >/dev/null 2>&1 || true; }
  fi
  ridge set "$new_item" --highlight on >/dev/null 2>&1 || true
  LAST_FOCUSED_WIN="$wid"
}

# The reconcile pass body, split from run_reconcile so temp-dir cleanup is an
# explicit wrapper concern: a `trap .. RETURN` here would fire on every inner
# function's return under `set -o functrace` (bash inherits RETURN traps
# there; bats runs tests that way), deleting the workdir mid-pass.
_run_reconcile_pass() {
  local tmp="$1"
  aerospace list-monitors --format '%{monitor-id}'$'\t''%{monitor-name}' >"$tmp/monitors" 2>/dev/null || return 0
  aerospace list-workspaces --monitor all \
    --format '%{workspace}'$'\t''%{monitor-name}'$'\t''%{workspace-is-focused}'$'\t''%{workspace-is-visible}' \
    >"$tmp/workspaces" 2>/dev/null || return 0
  # A FAILED query must NOT be treated as an empty window list: diffing
  # against it would remove every window item - a visible collapse - and
  # wipe the visible workspaces' rows from the order cache. Skip the pass;
  # the next event reconciles for real.
  aerospace list-windows --all \
    --format '%{workspace}'$'\t''%{window-id}'$'\t''%{app-name}'$'\t''%{window-layout}' >"$tmp/windows" 2>/dev/null || return 0
  # Capture the focused window IMMEDIATELY after the workspace/window snapshot
  # and BEFORE the slower osascript position query below. AeroSpace has no
  # per-window "is-focused" token, so focus is a separate query; if it ran
  # after the ~100ms osascript call, focus could drift in that gap and
  # focused_win would no longer match the captured windows - the highlight
  # then lands on the wrong window, or none. The ordering step below only
  # reorders window rows, so it is safe to run after this capture.
  local focused_win; focused_win="$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null | head -1)"
  # One osascript call per reconcile (reconcile itself is debounced, bounding
  # the added latency): builds the full window-id -> (x, y) map up front, so
  # ordering never shells out per workspace or per window.
  : >"$tmp/positions"
  if _have osascript; then
    local sig; sig="$(cksum <"$tmp/windows")"
    if [[ "$sig" == "$LAST_WINDOWS_SIG" && "$POS_REUSED" == "0" && -n "$POS_CACHE_FILE" && -s "$POS_CACHE_FILE" ]]; then
      # Unchanged window set: reuse the previous position map (skips the
      # ~100ms osascript call on the trailing pass of an event burst).
      cp "$POS_CACHE_FILE" "$tmp/positions" 2>/dev/null || : >"$tmp/positions"
      POS_REUSED=1
    else
      osascript -l JavaScript "${PLUGIN_ROOT}/window_positions.js" >"$tmp/positions" 2>/dev/null || : >"$tmp/positions"
      [[ -n "$POS_CACHE_FILE" ]] || POS_CACHE_FILE="$(mktemp)"
      cp "$tmp/positions" "$POS_CACHE_FILE" 2>/dev/null || true
      LAST_WINDOWS_SIG="$sig"
      POS_REUSED=0
    fi
  fi
  if _order_windows_by_position "$tmp/windows" "$tmp/positions" >"$tmp/windows_ordered" 2>/dev/null; then
    mv "$tmp/windows_ordered" "$tmp/windows"
  fi
  [[ -n "$ORDER_CACHE_FILE" ]] || ORDER_CACHE_FILE="$(mktemp)"
  if _stabilize_hidden_order "$tmp/windows" "$tmp/workspaces" "$ORDER_CACHE_FILE" "$tmp/positions" >"$tmp/windows_stable" 2>/dev/null; then
    mv "$tmp/windows_stable" "$tmp/windows"
  fi

  desired_state "$tmp/monitors" "$tmp/workspaces" "$tmp/windows" "$focused_win" >"$tmp/desired"
  # Persist the window-id -> item-id map for _fast_path_window_focus. Written
  # atomically-enough for its consumer (awk first-match lookups; a torn read
  # just misses the fast path once). LAST_FOCUSED_WIN follows the snapshot so
  # the fast path's next unhighlight aims at the pill this pass painted.
  [[ -n "$WIN_MAP_FILE" ]] || WIN_MAP_FILE="$(mktemp)"
  awk -F'\t' '$1 == "WMAP" { print $2 "\t" $3 }' "$tmp/desired" >"$WIN_MAP_FILE"
  [[ -n "$focused_win" ]] && LAST_FOCUSED_WIN="$focused_win"
  # Lazy mktemp for tests that source this script without calling main().
  [[ -n "$CLICK_MAP_FILE" ]] || CLICK_MAP_FILE="$(mktemp)"
  # A FAILED query must NOT be treated as an empty store. If it were (the old
  # `|| echo []` behavior), current_state would look empty, the reconcile would
  # try to re-add every existing item - each failing with "duplicate item id" -
  # and never issue the `set` that updates colors, leaving the bar frozen with
  # stale focus highlights. Skip this pass instead; the next event reconciles
  # against a real snapshot.
  if ! ridge query items >"$tmp/items.json" 2>/dev/null \
     || ! ridge query brackets >"$tmp/brackets.json" 2>/dev/null; then
    echo "aerospace-apps-plugin: ridge query failed; skipping reconcile (avoids a frozen bar)" >&2
    return 0
  fi
  current_state "$tmp/items.json" "$tmp/brackets.json" >"$tmp/current"

  # Apply every emitted command over ONE `ridge batch` connection instead of one
  # `ridge` process + round-trip each. The API server shares the MainActor with
  # rendering, so under CPU load a single round-trip costs ~1s and N sequential
  # ones multiplied that (10 commands: 0.86s idle -> 10.7s loaded) - which is
  # what made the aerospace widgets crawl while other apps stayed responsive.
  # Tokenizing stays in bash (`eval set --` is a builtin, no fork), so
  # reconcile() keeps emitting the same %q-quoted lines and `ridge batch` never
  # has to re-implement shell quoting: args go out NUL-separated, commands
  # RS-separated.
  local cmd batch_status=0
  {
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      # Self-generated by reconcile() with %q-quoted values, so re-parsing is safe.
      # shellcheck disable=SC2294
      eval "set -- $cmd" || continue
      shift                         # drop the leading `ridge`
      (( $# )) || continue
      printf '%s\0' "$@"
      printf '\036'
    done < <(reconcile "$tmp/desired" "$tmp/current" "$CLICK_MAP_FILE")
  } | ridge batch || batch_status=$?
  [[ "$batch_status" == "0" ]] || echo "aerospace-apps-plugin: one or more batched commands failed" >&2
  # Persist this pass's desired clicks as the "last applied" baseline for the
  # next pass's staleness check. Reconcile already consumed the PREVIOUS
  # contents above (the `done < <(...)` blocked until it finished), so
  # overwriting here is safe. Wholesale overwrite from tmp/desired (not an
  # in-place update) means an id no longer desired just drops out.
  awk -F'\t' '$1 == "ITEM" { print $2 "\t" $7 }' "$tmp/desired" >"$CLICK_MAP_FILE"
}

# Whether a workspace's windows this pass have a position reading the
# ordering can trust, one "ws\t0|1" row per workspace present in windows_tsv.
# AeroSpace parks every window of a hidden workspace at one off-screen point
# (verified live: 4 windows all at the same x,y), so a position "resolves"
# for a workspace only if at least one of its windows has an entry in
# positions_tsv AND, when 2+ windows have entries, they are not all the
# identical coordinate (a real tie). A workspace with zero or one positioned
# window is trivially resolved - there is nothing to tie-break.
_ws_resolved_workspaces() {
  local windows_tsv="$1" positions_tsv="$2"
  awk -F'\t' -v OFS='\t' -v posfile="$positions_tsv" '
    FILENAME == posfile {
      if (NF < 3) next
      px[$1] = $2; py[$1] = $3; hasp[$1] = 1
      next
    }
    {
      ws = $1; wid = $2
      wsall[ws] = 1
      if (hasp[wid]) {
        seen[ws]++
        if (ws in fx) { if (fx[ws] != px[wid] || fy[ws] != py[wid]) samepos[ws] = 0 }
        else { fx[ws] = px[wid]; fy[ws] = py[wid]; samepos[ws] = 1 }
      }
    }
    END {
      for (ws in wsall) {
        tiecase = (seen[ws] >= 2 && samepos[ws] == 1)
        resolved = (seen[ws] > 0) && !tiecase
        print ws, (resolved ? 1 : 0)
      }
    }
  ' "$positions_tsv" "$windows_tsv"
}

# AeroSpace stashes every window of a hidden workspace at one off-screen
# point, so for those the position sort ties and falls back to aerospace's
# unstable list order. This plugin only renders visible workspaces' windows,
# but the ordering helper is shared verbatim with aerospace_workspaces so
# the underlying windows_tsv ordering (feeding both) behaves identically; see
# that plugin's copy of this function for the full hidden-workspace
# rationale. positions_tsv is optional (defaults to no positions, i.e. every
# workspace unresolved) for callers/tests that only care about the
# cache-freeze behavior.
_stabilize_hidden_order() {
  local windows_tsv="$1" workspaces_tsv="$2" cache_file="$3" positions_tsv="${4:-/dev/null}"
  [[ -f "$positions_tsv" ]] || positions_tsv="/dev/null"

  local res_file; res_file="$(mktemp)"
  _ws_resolved_workspaces "$windows_tsv" "$positions_tsv" >"$res_file"

  awk -F'\t' -v OFS='\t' -v wsfile="$workspaces_tsv" -v resfile="$res_file" -v cachefile="$cache_file" '
    FILENAME == wsfile { if ($3 == "true" || $4 == "true") vis[$1] = 1; next }
    FILENAME == resfile { resolved[$1] = $2; next }
    FILENAME == cachefile { rank[$1 SUBSEP $2] = ++cr[$1]; cachecount[$1] = 1; next }
    {
      ws = $1; wid = $2
      if (!(ws in gorder)) gorder[ws] = ++gseq
      n++
      if (vis[ws] && resolved[ws] == "1") key = n
      else if ((ws SUBSEP wid) in rank) key = rank[ws, wid]
      else if (!(ws in cachecount)) key = wid + 0
      else key = 1000000000 + n
      printf "%d\t%d\t%d\t%s\n", gorder[ws], key, n, $0
    }
  ' "$workspaces_tsv" "$res_file" "$cache_file" "$windows_tsv" \
    | sort -t $'\t' -k1,1n -k2,2n -k3,3n \
    | cut -f4-

  # Refresh the cache: a resolved+visible workspace's rows come from this
  # pass's (position-sorted) order; every other workspace's rows are kept
  # verbatim from the old cache, pruned to windows that are still live (open,
  # and still recorded under the same workspace in windows_tsv) and to
  # workspaces that still exist. Dead window-ids and vanished workspaces are
  # dropped here, bounding the cache file.
  local newcache
  newcache="$(awk -F'\t' -v OFS='\t' -v wsfile="$workspaces_tsv" -v resfile="$res_file" -v cachefile="$cache_file" '
    FILENAME == wsfile { wsexists[$1] = 1; if ($3 == "true" || $4 == "true") vis[$1] = 1; next }
    FILENAME == resfile { resolved[$1] = $2; next }
    FILENAME == cachefile { oldn++; oldrow[oldn] = $0; oldws[oldn] = $1; oldwid[oldn] = $2; next }
    {
      ws = $1; wid = $2
      live[ws SUBSEP wid] = 1
      if (vis[ws] && resolved[ws] == "1") print ws, wid
    }
    END {
      for (i = 1; i <= oldn; i++) {
        ws = oldws[i]; wid = oldwid[i]
        if (!(ws in wsexists)) continue
        if (vis[ws] && resolved[ws] == "1") continue
        if (!((ws SUBSEP wid) in live)) continue
        print oldrow[i]
      }
    }
  ' "$workspaces_tsv" "$res_file" "$cache_file" "$windows_tsv")"

  rm -f "$res_file"

  # Atomic write: two plugin instances can overlap during a daemon restart, so
  # readers of the persistent cache must never observe a partially-written
  # file. Write to a sibling temp file, then rename over the real path.
  local tmpcache="${cache_file}.tmp.$$"
  if [[ -n "$newcache" ]]; then
    printf '%s\n' "$newcache" >"$tmpcache"
  else
    : >"$tmpcache"
  fi
  mv -f "$tmpcache" "$cache_file"
}

run_reconcile() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  _run_reconcile_pass "$tmp" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# Cross-process single-flight + coalesce mutex around run_reconcile. macOS has
# no flock; mkdir is atomic across processes, so it is the lock primitive
# here. Every reconcile call site (subscribe/poll's SIGUSR1 trap, the
# subscribe pipeline's own subshell, trigger_loop's drain, poll_loop) routes
# through this instead of calling run_reconcile directly, so two processes
# can never run a pass at the same time against the same non-atomic cache
# files (POS_CACHE_FILE, WIN_MAP_FILE) or the same ridge item store.
#
# Lock held elsewhere: don't run, just leave a redo flag and return - the
# holder drains it below before releasing, so whatever changed during its
# pass still gets exactly one coalesced follow-up run, never a second
# concurrent run_reconcile.
#
# Lock acquired: loop run_reconcile, clearing the redo flag before each pass
# so only a redo requested DURING that pass (not before it) triggers another.
# Private, per-user, 0700 lock/redo location - NEVER world-writable /tmp. A
# predictable /tmp path (pid is not secret) would let another local user
# pre-plant a symlink at the redo flag and redirect the `: >` truncation onto
# an arbitrary file the user owns (CWE-59).
_reconcile_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/aerospace_apps"
  if mkdir -p "$dir" 2>/dev/null && chmod 0700 "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    printf '%s' "$dir"
  else
    printf '%s' "$(mktemp -d)"
  fi
}
RECONCILE_STATE_DIR="$(_reconcile_state_dir)"
RECONCILE_LOCK_DIR="$RECONCILE_STATE_DIR/reconcile.${MAIN_PID}.lock"
RECONCILE_REDO_FLAG="$RECONCILE_STATE_DIR/reconcile.${MAIN_PID}.redo"
# No flock means no auto-release on a crash mid-pass; a lock this old is
# treated as abandoned rather than genuinely in flight, so a wedged lock
# self-heals instead of blocking reconcile forever.
RECONCILE_LOCK_MAX_AGE=30

run_reconcile_guarded() {
  # Belt-and-braces with the private 0700 dir: never write through a symlinked
  # redo flag.
  [[ -L "$RECONCILE_REDO_FLAG" ]] && rm -f "$RECONCILE_REDO_FLAG"

  while true; do
    if ! mkdir "$RECONCILE_LOCK_DIR" 2>/dev/null; then
      local acquired now
      acquired="$(cat "$RECONCILE_LOCK_DIR/acquired_at" 2>/dev/null || echo 0)"
      now="$(date +%s)"
      if (( now - acquired >= RECONCILE_LOCK_MAX_AGE )); then
        rm -rf "$RECONCILE_LOCK_DIR" 2>/dev/null || true
        mkdir "$RECONCILE_LOCK_DIR" 2>/dev/null || { : >"$RECONCILE_REDO_FLAG"; return 0; }
      else
        : >"$RECONCILE_REDO_FLAG"
        return 0
      fi
    fi
    date +%s >"$RECONCILE_LOCK_DIR/acquired_at" 2>/dev/null || true

    while true; do
      rm -f "$RECONCILE_REDO_FLAG"
      run_reconcile || true                        # a failed pass must still release the lock below
      [[ -e "$RECONCILE_REDO_FLAG" ]] || break
    done
    rm -rf "$RECONCILE_LOCK_DIR" 2>/dev/null || true

    # Close the check-then-release window: a redo requested between the inner
    # loop's last check and the release above would otherwise be dropped. Re-loop
    # to re-acquire and drain it; if another process grabbed the lock meanwhile,
    # our mkdir fails and we re-set the redo for that holder to handle.
    [[ -e "$RECONCILE_REDO_FLAG" ]] || break
  done
}

_have() { command -v "$1" >/dev/null 2>&1; }

# One subscribe event (plus whatever queued behind it) -> leading-edge update:
# the fast-path highlight and a full reconcile run immediately, then events
# that queued while they ran coalesce into one trailing follow-up pass. This
# replaces the old trailing-edge debounce, whose flat 100ms pre-wait (extended
# by every event in the burst) delayed the first visible change.
_on_subscribe_event() {
  # Orphan guard: if the main process died, this subshell must not keep
  # reconciling against the socket - exit and let the pipe collapse.
  kill -0 "$MAIN_PID" 2>/dev/null || exit 0
  _fast_path_window_focus
  run_reconcile_guarded
  local had_more=0
  while IFS= read -r -t 0.1 _more; do had_more=1; done
  if [[ "$had_more" == "1" ]]; then
    kill -0 "$MAIN_PID" 2>/dev/null || exit 0
    _fast_path_window_focus
    run_reconcile_guarded
  fi
}

# Event-driven: reconcile on every aerospace event via `aerospace subscribe`,
# reconnecting with backoff if the stream ends.
subscribe_loop() {
  local backoff=1
  while true; do
    # Explicit reconcile on (re)connect: don't rely on subscribe's initial
    # burst to paint the bar. Idempotent full diff, so a redundant call once
    # events also arrive is harmless.
    run_reconcile_guarded
    # Each connect sends an initial burst; every event line triggers a
    # leading-edge update (see _on_subscribe_event).
    if aerospace subscribe --all 2>/dev/null | while IFS= read -r _line; do
         _on_subscribe_event
       done; then :; fi
    # Stream ended: AeroSpace is gone/restarting. The workspaces sibling
    # plugin owns the "AeroSpace down" warning; this plugin just reconnects.
    echo "aerospace-apps-plugin: subscribe stream ended; reconnecting in ${backoff}s" >&2
    sleep "$backoff"
    backoff=$(( backoff < 8 ? backoff * 2 : 8 ))
  done
}

# Reconcile only when externally triggered by `ridge trigger aerospace_apps`
# (delivered as SIGUSR1 by the plugin supervisor). The user wires it into
# ~/.aerospace.toml exec-on-workspace-change hooks. The trap only SETS a flag
# (never calls run_reconcile directly), so a signal arriving DURING a
# reconcile cannot re-enter it; it is drained at the top of the next loop
# iteration, coalescing rapid triggers into one follow-up reconcile. The
# drain itself goes through run_reconcile_guarded (not run_reconcile) so a
# trigger and a SIGUSR1 from a display-change event share the one
# cross-process lock too.
trigger_loop() {
  local pending=0
  trap 'pending=1' USR1
  run_reconcile_guarded                          # initial paint
  while true; do
    while [[ "$pending" == "1" ]]; do            # drain triggers (coalesced)
      pending=0
      run_reconcile_guarded
    done
    # Bounded (not ~68 years): a SIGUSR1 landing in the tiny window between the
    # drain check and `wait` starting sets pending but does not interrupt the wait;
    # the 1s cap re-drains it, so a lost wakeup self-heals within 1s instead of
    # waiting for the next trigger. A received signal still interrupts immediately.
    sleep 1 & local spid=$!
    wait "$spid" 2>/dev/null || true             # woken by SIGUSR1 or the 1s cap
    kill "$spid" 2>/dev/null || true             # reap the sleep so it never leaks
  done
}

# Interval-driven: reconcile every SETTING_poll_interval seconds, no subscribe.
# A fallback for setups where `aerospace subscribe` is unreliable, or for a fixed
# update cadence.
poll_loop() {
  while true; do
    run_reconcile_guarded
    sleep "$SETTING_poll_interval"
  done
}

# Subscribe-mode safety backstop. AeroSpace emits NO window-closed/destroyed
# event (its events are focus/workspace/monitor/mode/window-detected/binding),
# so a window closed without also moving focus - or a `list-windows` that still
# reports the just-closed window at the focus-changed event - leaves a stale
# pill until some later unrelated event reconciles. A slow periodic SIGUSR1
# drives run_reconcile_guarded (the same trap display-change uses), clearing the
# stale pill within poll_interval seconds. It stays a backstop, not the primary
# path: reconcile is a no-op diff when nothing changed, and its position query
# is cached on an unchanged window set, so a steady bar costs only the aerospace
# list queries. Runs as a child that dies with the plugin (target-PID kill guard
# + EXIT cleanup).
_start_safety_heartbeat() {
  local target_pid="$1" interval="$2"
  ( while true; do
      sleep "$interval"
      kill -0 "$target_pid" 2>/dev/null || exit 0   # parent gone: stop
      kill -USR1 "$target_pid" 2>/dev/null || exit 0
    done ) &
  SAFETY_HEARTBEAT_PID=$!
}

# `ridge trigger <name>` sends SIGUSR1 to this process regardless of the
# update mode (the supervisor cannot know which mode the script chose), and so
# does DisplayManager.onDisplaySetChanged on a monitor plug/unplug: a
# subscribe-mode plugin's own event stream (workspace/window/focus) never
# reports a topology change, so it must also react to this signal, not just
# ignore it. trigger_loop installs its own coalescing trap (a signal mid-pass
# must not re-enter run_reconcile); subscribe/poll have no pass running most
# of the time - they are blocked in the subscribe pipeline's wait or in
# sleep - so the signal is only ever delivered to THIS top-level process
# there, and bash runs the trap to completion, then resumes the interrupted
# wait/sleep.
#
# The trap calls run_reconcile_guarded, not run_reconcile directly: in
# subscribe mode the pipeline subshell also reconciles on every aerospace
# event, on its own schedule, independent of this trap - a signal landing
# while that subshell is mid-pass must not start a second, concurrent pass
# against the same cache files. The guard makes that safe: a signal during an
# in-flight pass just leaves a redo flag and returns immediately.
_install_signal_policy() {
  case "$1" in subscribe|poll) trap 'run_reconcile_guarded' USR1 ;; esac
}

# Points ORDER_CACHE_FILE at the persistent order-cache dir (creating it if
# needed). If the dir cannot be made writable - permissions, a read-only
# mount, a full disk - degrade to a session-scoped mktemp cache instead of
# silently disabling order-freezing for the whole process; sets
# ORDER_CACHE_IS_FALLBACK so main()'s EXIT trap knows to clean that mktemp
# file up, and logs once so the degradation is visible.
_setup_order_cache() {
  local dir="$1"
  mkdir -p "$dir" 2>/dev/null || true
  if [[ -d "$dir" && -w "$dir" ]]; then
    ORDER_CACHE_FILE="$dir/ws_order"
    [[ -f "$ORDER_CACHE_FILE" ]] || : >"$ORDER_CACHE_FILE"
    # Stale tmp+rename siblings from a prior crash mid-write (the write..mv
    # window in _stabilize_hidden_order's atomic write) never got cleaned up
    # by their own writer. Safe to clear on startup: a concurrent writer (two
    # plugin instances overlapping during a daemon restart) re-creates its
    # own within milliseconds, and a write lost to this race just self-heals
    # on the next reconcile pass.
    rm -f "$dir"/ws_order.tmp.* 2>/dev/null || true
    ORDER_CACHE_IS_FALLBACK=0
  else
    echo "aerospace-apps-plugin: order cache dir '$dir' is not writable; falling back to a session-only cache (window order will not persist across restarts)" >&2
    ORDER_CACHE_FILE="$(mktemp)"
    ORDER_CACHE_IS_FALLBACK=1
  fi
}

main() {
  for dep in jq aerospace ridge; do
    if ! _have "$dep"; then echo "aerospace-apps-plugin: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "aerospace-apps-plugin: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # Create the position-cache file here, not lazily in _run_reconcile_pass: in
  # subscribe mode that pass runs in the pipeline subshell, whose state dies
  # with each connection - a lazy mktemp there would orphan one file per
  # reconnect. A pre-created path survives reconnects (the subshell-local
  # validity state resetting just means one extra osascript pass) and is
  # removed on process exit.
  POS_CACHE_FILE="$(mktemp)"
  WIN_MAP_FILE="$(mktemp)"
  CLICK_MAP_FILE="$(mktemp)"

  # Persistent hidden-workspace order cache: unlike POS_CACHE_FILE/
  # WIN_MAP_FILE/CLICK_MAP_FILE above, this must survive a plugin restart -
  # the daemon restarts frequently, and a mktemp cache reset on every launch
  # let the first capture after a restart freeze aerospace's unstable
  # tie-broken list order.
  _setup_order_cache "${XDG_CACHE_HOME:-$HOME/.cache}/ridge/aerospace_apps"

  # POS_CACHE_FILE/WIN_MAP_FILE/CLICK_MAP_FILE are per-run scratch state,
  # always mktemp. ORDER_CACHE_FILE is normally the persistent cache itself
  # (left alone on exit); only clean it up here when _setup_order_cache fell
  # back to a session-only mktemp file.
  trap 'rm -f "$POS_CACHE_FILE" "$WIN_MAP_FILE" "$CLICK_MAP_FILE"; [[ -n "${SAFETY_HEARTBEAT_PID:-}" ]] && kill "$SAFETY_HEARTBEAT_PID" 2>/dev/null; [[ "$ORDER_CACHE_IS_FALLBACK" == "1" ]] && rm -f "$ORDER_CACHE_FILE"' EXIT

  _install_signal_policy "$SETTING_update_mode"
  # Subscribe mode has no window-close event; a slow SIGUSR1 heartbeat backstops
  # it (see _start_safety_heartbeat). Poll mode already reconciles on its own
  # interval; trigger mode is externally driven - neither needs the heartbeat.
  case "$SETTING_update_mode" in subscribe|"") _start_safety_heartbeat "$$" "$SETTING_poll_interval" ;; esac
  case "$SETTING_update_mode" in
    subscribe) subscribe_loop ;;
    trigger)   trigger_loop ;;
    poll)      poll_loop ;;
    *)         subscribe_loop ;;
  esac
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so the
# guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

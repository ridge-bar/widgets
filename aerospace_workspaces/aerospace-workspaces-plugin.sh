#!/usr/bin/env bash
# Ridge AeroSpace Workspaces plugin: dynamic per-monitor workspace pills
# (number + per-window glyphs) driven by `aerospace subscribe`. Launched and
# supervised by Ridge; talks to ridge over $RIDGE_SOCKET via the `ridge` CLI.
# Split from the former combined `aerospace` plugin: this half owns the
# workspace bubbles and the "AeroSpace down" status warning. The center
# window/app list is the sibling `aerospace_apps` plugin. See README.md.
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

# Tracks whether the aerospace_ws.status "AeroSpace down" warning is currently
# shown, so subscribe_loop's reconnect branch and run_reconcile's success
# path only call ridge on an actual shown<->hidden transition, not on every
# reconnect attempt / reconcile pass.
AEROSPACE_DOWN_SHOWN=0

# Fast-path focus tracking: the workspace (and its monitor - the ws pill id
# is monitor-keyed, so unhighlighting the OLD pill needs the monitor it was
# last painted on, not just its name) whose pill the fast path last
# highlighted. The full reconcile's HL pass is idempotent over it.
LAST_FOCUSED_WS=""
LAST_FOCUSED_WS_MON=""

# Window-position cache (run_reconcile): the osascript position query is the
# slowest reconcile step (~100ms), so when the window snapshot is unchanged
# the previous map is reused - at most once in a row, so a window moved
# without any window-set change re-sorts one pass later, never goes stale
# indefinitely.
LAST_WINDOWS_SIG=""
POS_REUSED=0
POS_CACHE_FILE=""

# Last-visible window order per workspace (ws\twid rows), maintained by
# _stabilize_hidden_order so hidden workspaces keep their glyph order. main()
# points this at a persistent path under XDG_CACHE_HOME so the order survives
# a plugin restart, not a mktemp file reset every launch; tests that source
# this script without calling main() get a lazy mktemp fallback in
# _run_reconcile_pass instead.
ORDER_CACHE_FILE=""
# 1 when ORDER_CACHE_FILE is a session-only mktemp fallback (the persistent
# cache dir was not writable), so main()'s EXIT trap knows to clean it up the
# same way it always cleaned up the old round-1 mktemp cache. 0 when
# ORDER_CACHE_FILE is the real persistent path and must survive process exit.
ORDER_CACHE_IS_FALLBACK=0

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this plugin's
# own eval; the click's workspace name must survive both.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# --font/--font-style/--font-size flags for an app-glyph item (app_icon's
# ligature only renders as an icon in the configured app_font, not the bar's
# default font). Each value is %q-quoted: this is assembled into a line
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
# corner_radius) omits the flag entirely so ridge core's global
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

# shellcheck disable=SC2034 # SETTING_* (including the Tokyo Night styling keys, per-item paddings, bubble_margin, and border settings) are consumed by main() and reconcile(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_focused_color="$(jq -r '.focused_color // "#7AA2F7"' <<<"$json")"
  SETTING_normal_color="$(jq -r '.normal_color // "#C0CAF5"' <<<"$json")"
  SETTING_bg_color="$(jq -r '.bg_color // "theme:background"' <<<"$json")"
  SETTING_region="$(jq -r '.region // "left"' <<<"$json")"
  # Region for the aerospace_ws.status "AeroSpace down" warning item.
  SETTING_status_region="$(jq -r '.status_region // "right"' <<<"$json")"
  SETTING_show_empty="$(jq -r '.show_empty_workspaces // false' <<<"$json")"
  # Font for the pills (e.g. a patched Nerd Font family) so app glyphs render.
  # Empty -> no --font passed (the item uses ridge's bar.font/system default).
  SETTING_font="$(jq -r '.font // ""' <<<"$json")"
  SETTING_font_size="$(jq -r '.font_size // ""' <<<"$json")"
  # Font for app-glyph ligatures; these only resolve to icon glyphs in a font
  # that defines the ligatures. Empty (the default) -> app icons render as
  # literal ":app_name:" text.
  SETTING_app_font="$(jq -r '.app_font // ""' <<<"$json")"
  SETTING_app_font_style="$(jq -r '.app_font_style // "Regular"' <<<"$json")"
  [[ -n "$SETTING_app_font_style" ]] || SETTING_app_font_style="Regular"
  SETTING_app_font_size="$(jq -r '.app_font_size // "14"' <<<"$json")"
  [[ "$SETTING_app_font_size" =~ ^[0-9]*\.?[0-9]+$ ]] || SETTING_app_font_size="14"
  # Tokyo Night styling keys for the multi-item bubble.
  # bg_focused_color/glyph_focused_color fall back to the old
  # focused_color/normal_color keys so an existing ridge.yaml still works.
  SETTING_bg_focused_color="$(jq -r '.bg_focused_color // .focused_color // "theme:system"' <<<"$json")"
  SETTING_number_color="$(jq -r '.number_color // "theme:secondary"' <<<"$json")"
  SETTING_glyph_color="$(jq -r '.glyph_color // "theme:primary@0.5"' <<<"$json")"
  SETTING_glyph_focused_color="$(jq -r '.glyph_focused_color // .normal_color // "theme:primary"' <<<"$json")"
  SETTING_corner_radius="$(jq -r '.corner_radius // ""' <<<"$json")"
  SETTING_height="$(jq -r '.height // ""' <<<"$json")"
  SETTING_max_ws_apps="$(jq -r '.max_ws_apps // "5"' <<<"$json")"
  # Per-item padding so the number + glyph items in a workspace bubble sit
  # tight, with slightly more room right of the number.
  SETTING_num_pad_left="$(jq -r '.num_pad_left // "8"' <<<"$json")"
  SETTING_num_pad_right="$(jq -r '.num_pad_right // "4"' <<<"$json")"
  SETTING_glyph_pad_left="$(jq -r '.glyph_pad_left // "8"' <<<"$json")"
  SETTING_glyph_pad_right="$(jq -r '.glyph_pad_right // "8"' <<<"$json")"
  # Per-bracket margin widening the gap between workspace bubbles.
  SETTING_bubble_margin="$(jq -r '.bubble_margin // "6"' <<<"$json")"
  # Focus is shown as a border on the bubble bracket, not a bg-color swap.
  SETTING_border_focused_color="$(jq -r '.border_focused_color // "theme:system"' <<<"$json")"
  SETTING_border_width="$(jq -r '.border_width // "2"' <<<"$json")"
  # Update strategy: "subscribe" (default, aerospace subscribe stream), "trigger"
  # (reconcile on `ridge trigger aerospace_workspaces`), or "poll" (interval). Unknown -> subscribe.
  SETTING_update_mode="$(jq -r '.update_mode // "subscribe"' <<<"$json")"
  case "$SETTING_update_mode" in subscribe|trigger|poll) ;; *) SETTING_update_mode="subscribe" ;; esac
  # Poll interval in seconds (poll mode only). Must be a positive number, else
  # default 2 - a zero-equivalent (0, 00, .0, 0.00) would make `sleep` return
  # instantly and turn poll mode into a CPU-hammering tight loop. Stripping all
  # dots and zeros leaves nothing iff the value is zero-equivalent.
  SETTING_poll_interval="$(jq -r '.poll_interval // "2"' <<<"$json")"
  [[ "$SETTING_poll_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_poll_interval//[.0]/}" ]] || SETTING_poll_interval="2"
  # Color for the aerospace_ws.status "AeroSpace down" warning item (shown in
  # status_region when the subscribe stream disconnects).
  SETTING_status_color="$(jq -r '.status_color // "theme:error"' <<<"$json")"
}

# True if the workspace has at least one window in windows.tsv (i.e. non-empty).
# aerospace has no workspace-is-empty format token, so emptiness is derived here.
_workspace_has_windows() {
  local ws="$1" windows_tsv="$2" w rest
  while IFS=$'\t' read -r w rest; do
    [[ "$w" == "$ws" ]] && return 0
  done <"$windows_tsv"
  return 1
}

# Sort-key columns for an item id, used by reconcile to order the strip:
#   <mon>\t<ws>\t<kind>\t<idx>
# Workspace items (aerospace_ws.<monSan>.<wsSan>.*) sort by monitor, then
# workspace-natural, number first, then glyphs in window order.
_item_sortkey() {
  local id="$1" rest kind idx
  rest="${id#aerospace_ws.}"           # <monSan>.<wsSan>.num|app.<i>
  local monSan ws
  monSan="${rest%%.*}"
  ws="${rest#*.}"
  ws="${ws%%.*}"
  case "$rest" in
    *.num)   kind=0; idx=0;;
    *.app.*) kind=1; idx="${rest##*.}";;
    *)       kind=2; idx=0;;
  esac
  printf '%s\t%s\t%s\t%s' "$monSan" "$ws" "$kind" "$idx"
}

# One line per window in $ws (windows_tsv order), capped at $max:
#   <glyph>\t<foc>   (foc=1 when window-id == $focused_win).
# windows_tsv columns: workspace, window-id, app-name, window-layout. The layout
# column is read only to keep it out of the app-name field; the window-list
# sibling plugin uses it, not this one.
_window_glyphs() {
  local ws="$1" windows_tsv="$2" focused_win="$3" max="$4"
  local w wid app layout g n=0
  # shellcheck disable=SC2034 # layout is read only to keep it out of the app field
  while IFS=$'\t' read -r w wid app layout; do
    [[ "$w" != "$ws" ]] && continue
    [[ -z "$app" ]] && continue
    n=$((n + 1))
    [[ "$n" -gt "$max" ]] && break
    g="$(app_icon "$app")"
    local foc=0; [[ -n "$focused_win" && "$wid" == "$focused_win" ]] && foc=1
    printf '%s\t%s\n' "$g" "$foc"
  done <"$windows_tsv"
}

desired_state() {
  # shellcheck disable=SC2034 # monitors_tsv kept for interface parity; monitor display name comes from workspaces_tsv
  local monitors_tsv="$1" workspaces_tsv="$2" windows_tsv="$3" focused_win="$4"
  local ws monitor focused visible show base click members i g foc col bbg

  # workspaces_tsv columns: workspace, monitor-name, is-focused, is-visible.
  # Emptiness is derived from windows_tsv (no aerospace workspace-is-empty token).
  # Each shown workspace becomes a bubble: a number item, one item per window
  # glyph, wrapped in a per-workspace bracket that draws the bg.
  while IFS=$'\t' read -r ws monitor focused visible; do
    [[ -z "$ws" ]] && continue
    show="no"
    if [[ "$SETTING_show_empty" == "true" || "$focused" == "true" || "$visible" == "true" ]]; then
      show="yes"
    elif _workspace_has_windows "$ws" "$windows_tsv"; then
      show="yes"
    fi
    [[ "$show" == "yes" ]] || continue

    # The id is keyed by monitor AND workspace, not just workspace name. When
    # a workspace remaps to a different monitor, the OLD id disappears from
    # desired_state and reconcile's stale-item pass removes it; the pill is
    # re-added under the NEW id with the correct --display, instead of a
    # name-keyed pill silently keeping a stale --display.
    base="aerospace_ws.$(sanitize "$monitor").$(sanitize "$ws")"
    # Single-quote the raw ws name for the sh -c layer ridge core runs the click on.
    click="aerospace workspace $(shq "$ws")"

    # Number item first (color is always number_color, focus is shown via the bracket bg).
    printf 'ITEM\t%s.num\t%s\t%s\t%s\t%s\t%s\n' \
      "$base" "$monitor" "$monitor" "$ws" "$SETTING_number_color" "$click"
    i=0; members="$base.num"
    while IFS=$'\t' read -r g foc; do
      i=$((i + 1))
      col="$SETTING_glyph_color"; [[ "$foc" == "1" ]] && col="$SETTING_glyph_focused_color"
      printf 'ITEM\t%s.app.%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$base" "$i" "$monitor" "$monitor" "$g" "$col" "$click"
      members="$members,$base.app.$i"
    done < <(_window_glyphs "$ws" "$windows_tsv" "$focused_win" "$SETTING_max_ws_apps")

    # Focus is shown by the bar's animated selection indicator (bar.selection),
    # so the bubble keeps a constant dark bg with no static border - the number
    # item is marked highlighted and the indicator follows it.
    bbg="$SETTING_bg_color"
    printf 'BRACKET\t%s\t%s\t%s\t%s\t%s\n' "$base" "$members" "$bbg" "$bbg" "0"
    if [[ "$focused" == "true" ]]; then printf 'HL\t%s.num\ton\n' "$base"; else printf 'HL\t%s.num\toff\n' "$base"; fi
  done <"$workspaces_tsv"
}

current_state() {
  local items_json="$1" brackets_json="$2"
  # Leaf items: workspace bubbles (aerospace_ws.*), managed by the generic
  # reconcile diff. `ridge query` exposes only text + color (not
  # display/monitor/click), so those columns are empty; reconcile diffs on
  # text + color, the fields that round-trip.
  jq -r '
    .[] | select(.id | startswith("aerospace_ws."))
    | "ITEM\t\(.id)\t\t\t\(.text)\t\(.color)\t"
  ' "$items_json"
  # Brackets. `query brackets` has no bg-color, so the bg column is empty;
  # reconcile then always re-applies the desired bg.
  jq -r '
    .[] | select(.id | startswith("aerospace_ws."))
    | "BRACKET\t\(.id)\t\(.members | join(","))\t"
  ' "$brackets_json"
}

reconcile() {
  local desired_file="$1" current_file="$2"
  declare -A d_display=() d_text=() d_color=() d_click=() d_bmem=() d_bbg=() d_bbc=() d_bbw=() d_hl=() \
             c_text=() c_color=() c_bmem=() c_bbg=()
  local tag a b c d e f line c_seq=""

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
  # Desired items in render order: workspace natural (1,2,10,web), number first,
  # then glyphs in window order.
  local d_seq
  d_seq="$(for id in "${!d_text[@]}"; do
             printf '%s\t%s\n' "$(_item_sortkey "$id")" "$id"
           done | sort -t$'\t' -k1,1V -k2,2V -k3,3n -k4,4n | cut -f5)"
  # Incremental ordered reconcile: insert new items at their position, move only
  # genuinely-reordered items, set changed content. No whole-strip rebuild, so
  # opening a workspace never collapses the bar. ItemStore renders in store
  # order; --before/--after position an insert and `ridge move` repositions.
  local first_current
  first_current="$(printf '%s' "$c_seq" | head -n1)"
  # reorder = the items common to both differ in relative order (a genuine
  # shuffle, e.g. windows reordered within a bubble); pure insert/remove is not
  # a reorder and emits no moves.
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
      *.num)   local qnpl qnpr; printf -v qnpl '%q' "$SETTING_num_pad_left"; printf -v qnpr '%q' "$SETTING_num_pad_right"; pad=" --padding-left $qnpl --padding-right $qnpr" ;;
      *.app.*) local qgpl qgpr; printf -v qgpl '%q' "$SETTING_glyph_pad_left"; printf -v qgpr '%q' "$SETTING_glyph_pad_right"; pad=" --padding-left $qgpl --padding-right $qgpr" ;;
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
    # Route the workspace strip into the aerospace_ws container when the user
    # has placed a container anchor (an invisible type:container item id
    # "aerospace_ws"). Only the FIRST ws item carries --container; the rest
    # chain via --after prev, so intra-strip order is unchanged. Ridge ignores
    # --container when no anchor exists, so a config without one keeps
    # today's --before/--after placement (back-compat).
    local container_flag=""
    if [[ -z "$prev" ]]; then
      container_flag=" --container aerospace_ws"
    fi
    local region="$SETTING_region"
    if [[ -z "${c_text[$id]+set}" ]]; then
      # INSERT a new item at its position. App-glyph items (*.app.*) render
      # their ligature in the app-icon font; the number item keeps the bar font.
      local extra=""
      case "$id" in
        *.app.*) extra="$(_app_font_flags)" ;;
        *)
          if [[ -n "$SETTING_font" ]]; then
            local qfont; printf -v qfont '%q' "$SETTING_font"
            extra=" --font $qfont"
            [[ -n "$SETTING_font_size" ]] && extra="$extra --font-size $SETTING_font_size"
          fi
          ;;
      esac
      printf 'ridge add %s --region %q --display %q --text %q --color %q --click %q%s%s%s%s\n' \
        "$id" "$region" "${d_display[$id]}" "${d_text[$id]}" \
        "${d_color[$id]}" "${d_click[$id]}" "$extra" "$pad" "$anchor" "$container_flag"
    else
      # existing item: reposition only on a genuine reorder, and re-set content
      # (text/color/padding) when it changed.
      [[ "$reorder" == "1" ]] && printf 'ridge move %s%s\n' "$id" "$anchor"
      if [[ "${d_text[$id]}" != "${c_text[$id]}" || "${d_color[$id]}" != "${c_color[$id]}" ]]; then
        printf 'ridge set %s --text %q --color %q%s\n' "$id" "${d_text[$id]}" "${d_color[$id]}" "$pad"
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
    if [[ -z "${c_bmem[$id]+set}" ]]; then
      printf 'ridge bracket add %s --members %s --bg-color %q%s%s --margin %q --border-color %q --border-width %q\n' \
        "$id" "${d_bmem[$id]}" "${d_bbg[$id]}" "$cr_flag" "$height_flag" "$SETTING_bubble_margin" "${d_bbc[$id]}" "${d_bbw[$id]}"
    elif [[ "${d_bmem[$id]}" != "${c_bmem[$id]}" || "${d_bbg[$id]}" != "${c_bbg[$id]}" ]]; then
      printf 'ridge bracket set %s --members %s --bg-color %q%s%s --margin %q --border-color %q --border-width %q\n' \
        "$id" "${d_bmem[$id]}" "${d_bbg[$id]}" "$cr_flag" "$height_flag" "$SETTING_bubble_margin" "${d_bbc[$id]}" "${d_bbw[$id]}"
    fi
  done
  for id in "${!c_bmem[@]}"; do
    [[ -z "${d_bmem[$id]+set}" ]] && printf 'ridge bracket remove %s\n' "$id"
  done
  # Highlight AFTER items and brackets exist, so the bar's animated selection
  # indicator wraps the complete bubble the moment the highlight lands - not
  # the bare number first, then growing once the bracket arrives. Idempotent
  # on the bar side (updateHighlight no-ops when unchanged).
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
# order within a workspace changes, so every downstream consumer (glyphs,
# desired_state) is unaffected beyond the new visual ordering.
#
# Known limitation: accordion-layout windows overlap/cascade on screen, so an
# x-sort is not meaningful for them. No special accordion handling here - it
# is x-sorted like any other window, which is unreliable for that layout.
_order_windows_by_position() {
  local windows_tsv="$1" positions_tsv="$2"
  # FILENAME (not NR==FNR) distinguishes the two input files: NR==FNR would
  # stay true for the whole of windows_tsv too when positions_tsv is empty (0
  # records read from file 1 means FNR and NR advance together into file 2).
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

# Perceived-latency fast path: move the focus highlight the moment an event
# arrives, from one cheap focused-workspace query, before the full reconcile
# (which owns window lists, ordering, and pill add/remove). Highlight sets are
# idempotent bar-side, so the reconcile's own HL pass re-landing on the same
# pill is harmless. A pill that does not exist yet (hidden empty workspace)
# makes the `ridge set` fail silently; the reconcile that follows adds the
# pill and lands the highlight.
_fast_path_focus() {
  local line ws mon
  line="$(aerospace list-workspaces --focused --format '%{workspace}'$'\t''%{monitor-name}' 2>/dev/null | head -1)"
  IFS=$'\t' read -r ws mon <<<"$line"
  [[ -n "$ws" && "$ws" != "$LAST_FOCUSED_WS" ]] || return 0
  if [[ -n "$LAST_FOCUSED_WS" ]]; then
    ridge set "aerospace_ws.$(sanitize "$LAST_FOCUSED_WS_MON").$(sanitize "$LAST_FOCUSED_WS").num" --highlight off >/dev/null 2>&1 || true
  fi
  ridge set "aerospace_ws.$(sanitize "$mon").$(sanitize "$ws").num" --highlight on >/dev/null 2>&1 || true
  LAST_FOCUSED_WS="$ws"
  LAST_FOCUSED_WS_MON="$mon"
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
  # AeroSpace is responding again: clear the "AeroSpace down" warning, if shown.
  _clear_aerospace_down
  # A FAILED query must NOT be treated as an empty window list (same guard as
  # the ridge query below): diffing against it would remove every glyph item -
  # a visible collapse - and wipe the visible workspaces' rows from the order
  # cache. Skip the pass; the next event reconciles for real.
  aerospace list-windows --all \
    --format '%{workspace}'$'\t''%{window-id}'$'\t''%{app-name}'$'\t''%{window-layout}' >"$tmp/windows" 2>/dev/null || return 0
  # Capture the focused window IMMEDIATELY after the workspace/window snapshot
  # and BEFORE the slower osascript position query below. AeroSpace has no
  # per-window "is-focused" token, so focus is a separate query; if it ran
  # after the ~100ms osascript call, focus could drift in that gap (a focus
  # change lands there, or osascript perturbs focus) and focused_win would no
  # longer match the captured windows - the highlight then lands on the wrong
  # window, or none. The ordering step below only reorders window rows, so it is
  # safe to run after this capture.
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
  # A FAILED query must NOT be treated as an empty store. If it were (the old
  # `|| echo []` behavior), current_state would look empty, the reconcile would
  # try to re-add every existing item - each failing with "duplicate item id" -
  # and never issue the `set` that updates colors, leaving the bar frozen with
  # stale focus highlights. Skip this pass instead; the next event reconciles
  # against a real snapshot.
  if ! ridge query items >"$tmp/items.json" 2>/dev/null \
     || ! ridge query brackets >"$tmp/brackets.json" 2>/dev/null; then
    echo "aerospace-workspaces-plugin: ridge query failed; skipping reconcile (avoids a frozen bar)" >&2
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
    done < <(reconcile "$tmp/desired" "$tmp/current")
  } | ridge batch || batch_status=$?
  [[ "$batch_status" == "0" ]] || echo "aerospace-workspaces-plugin: one or more batched commands failed" >&2
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
# unstable list order - glyphs would swap whenever their workspace is not
# visible. Freeze instead: a workspace whose positions genuinely resolved
# this pass (see _ws_resolved_workspaces) keeps position order and refreshes
# the cache (ws\twid rows, per-workspace order); an unresolved workspace
# (hidden, or visible but tied/unpositioned) falls back to its cached
# last-visible order when one exists. When no cache exists yet for an
# unresolved workspace (the common case right after a plugin restart, before
# ORDER_CACHE_FILE's persistence had a chance to help, or for a workspace
# never seen visible), the tiebreak is deterministic ascending window-id -
# not aerospace's unstable list order - so the frozen order is at least
# stable across restarts. Uncached (new) windows in an otherwise-cached
# workspace sort after the cached ones, in current order. Workspace grouping
# is preserved throughout. positions_tsv is optional (defaults to no
# positions, i.e. every workspace unresolved) for callers/tests that only
# care about the cache-freeze behavior.
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
# through this instead of calling run_reconcile directly, so the two
# processes that used to race - the main process handling a signal and the
# pipeline subshell handling an aerospace event - can never run a pass at the
# same time against the same non-atomic cache files (POS_CACHE_FILE) or the
# same ridge item store.
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
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/aerospace_ws"
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

# Add-or-set idiom: try `ridge add` first, falling back to `ridge set
# ... --visible on` when the item already exists from a prior show/hide cycle.
_show_aerospace_down_status() {
  ridge add aerospace_ws.status --region "$SETTING_status_region" --text "AeroSpace down" \
    --color "$SETTING_status_color" \
    || ridge set aerospace_ws.status --text "AeroSpace down" --color "$SETTING_status_color" --visible on
}

_hide_aerospace_down_status() {
  ridge set aerospace_ws.status --visible off
}

# Gate the two functions above on AEROSPACE_DOWN_SHOWN so repeated reconnect
# attempts (subscribe_loop's backoff loop) and repeated successful reconciles
# (run_reconcile) only call ridge on an actual shown<->hidden transition.
_mark_aerospace_down() {
  if [[ "$AEROSPACE_DOWN_SHOWN" == "0" ]]; then
    _show_aerospace_down_status
    AEROSPACE_DOWN_SHOWN=1
  fi
}

_clear_aerospace_down() {
  if [[ "$AEROSPACE_DOWN_SHOWN" == "1" ]]; then
    _hide_aerospace_down_status
    AEROSPACE_DOWN_SHOWN=0
  fi
}

# One subscribe event (plus whatever queued behind it) -> leading-edge update:
# the fast-path highlight and a full reconcile run immediately, then events
# that queued while they ran coalesce into one trailing follow-up pass. This
# replaces the old trailing-edge debounce, whose flat 100ms pre-wait (extended
# by every event in the burst) delayed the first visible change.
_on_subscribe_event() {
  # Orphan guard: if the main process died, this subshell must not keep
  # reconciling against the socket - exit and let the pipe collapse.
  kill -0 "$MAIN_PID" 2>/dev/null || exit 0
  _fast_path_focus
  run_reconcile_guarded
  local had_more=0
  while IFS= read -r -t 0.1 _more; do had_more=1; done
  if [[ "$had_more" == "1" ]]; then
    kill -0 "$MAIN_PID" 2>/dev/null || exit 0
    _fast_path_focus
    run_reconcile_guarded
  fi
}

# Whether the last full reconcile pass actually painted at least one
# workspace bubble. `run_reconcile` itself always returns 0 even when a query
# failed (see _run_reconcile_pass) - it skips the pass rather than erroring,
# so its exit code can't tell a real paint from a silent no-op. Querying
# ridge directly afterward can.
_reconcile_painted_workspace() {
  ridge query items 2>/dev/null \
    | jq -e '[.[] | select(.id | startswith("aerospace_ws."))] | length > 0' >/dev/null 2>&1
}

# Self-heal: a reconcile right at connect can land before the API socket is
# renamed onto its public path, or before AeroSpace's own cold start has
# settled - `_run_reconcile_pass` treats either as "skip this pass" rather
# than an error, so the bar silently stays empty and subscribe_loop then
# blocks on aerospace's event stream, which may not fire again for a while.
# Retry a bounded number of times with a short sleep between attempts so a
# transient failure heals itself without needing a real workspace event;
# gives up quietly after the last attempt (a later real event still
# reconciles normally).
_reconcile_until_painted() {
  local attempts="${1:-5}" delay="${2:-0.3}" i
  for ((i = 1; i <= attempts; i++)); do
    run_reconcile_guarded
    _reconcile_painted_workspace && return 0
    (( i < attempts )) && sleep "$delay"
  done
  return 1
}

# Event-driven: reconcile on every aerospace event via `aerospace subscribe`,
# reconnecting with backoff if the stream ends.
subscribe_loop() {
  local backoff=1
  while true; do
    # Explicit reconcile on (re)connect: don't rely on subscribe's initial
    # burst to paint the bar. Idempotent full diff, so a redundant call once
    # events also arrive is harmless.
    _reconcile_until_painted
    # Each connect sends an initial burst; every event line triggers a
    # leading-edge update (see _on_subscribe_event).
    if aerospace subscribe --all 2>/dev/null | while IFS= read -r _line; do
         _on_subscribe_event
       done; then :; fi
    # Stream ended: AeroSpace is gone/restarting. Show the warning (once; a
    # later failed reconnect attempt re-enters this branch without re-showing).
    _mark_aerospace_down
    echo "aerospace-workspaces-plugin: subscribe stream ended; reconnecting in ${backoff}s" >&2
    sleep "$backoff"
    backoff=$(( backoff < 8 ? backoff * 2 : 8 ))
  done
}

# Reconcile only when externally triggered by `ridge trigger aerospace_workspaces`
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
# reports the just-closed window at the focus-changed event - leaves a stale app
# glyph in a workspace pill until some later unrelated event reconciles. A slow
# periodic SIGUSR1 drives run_reconcile_guarded (the same trap display-change
# uses), clearing it within poll_interval seconds. It stays a backstop, not the
# primary path: reconcile is a no-op diff when nothing changed. Runs as a child
# that dies with the plugin (target-PID kill guard + EXIT cleanup).
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
# needed) so hidden-workspace order survives a plugin restart. If the dir
# cannot be made writable - permissions, a read-only mount, a full disk -
# degrade to a session-scoped mktemp cache instead of silently disabling
# order-freezing for the whole process; sets ORDER_CACHE_IS_FALLBACK so
# main()'s EXIT trap knows to clean that mktemp file up, and logs once so the
# degradation is visible.
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
    echo "aerospace-workspaces-plugin: order cache dir '$dir' is not writable; falling back to a session-only cache (hidden workspace order will not persist across restarts)" >&2
    ORDER_CACHE_FILE="$(mktemp)"
    ORDER_CACHE_IS_FALLBACK=1
  fi
}

main() {
  for dep in jq aerospace ridge; do
    if ! _have "$dep"; then echo "aerospace-workspaces-plugin: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "aerospace-workspaces-plugin: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # Create the position-cache file here, not lazily in _run_reconcile_pass: in
  # subscribe mode that pass runs in the pipeline subshell, whose state dies
  # with each connection - a lazy mktemp there would orphan one file per
  # reconnect. A pre-created path survives reconnects (the subshell-local
  # validity state resetting just means one extra osascript pass) and is
  # removed on process exit.
  POS_CACHE_FILE="$(mktemp)"

  # Persistent hidden-workspace order cache: unlike POS_CACHE_FILE above, this
  # must survive a plugin restart - the daemon restarts frequently, and a
  # mktemp cache reset on every launch let the first capture after a restart
  # freeze aerospace's unstable tie-broken list order (every window of a
  # hidden workspace parks at one off-screen point, so position sort ties).
  _setup_order_cache "${XDG_CACHE_HOME:-$HOME/.cache}/ridge/aerospace_ws"

  # POS_CACHE_FILE is per-run scratch state, always mktemp. ORDER_CACHE_FILE
  # is normally the persistent cache itself (left alone on exit); only clean
  # it up here when _setup_order_cache fell back to a session-only mktemp file.
  trap 'rm -f "$POS_CACHE_FILE"; [[ -n "${SAFETY_HEARTBEAT_PID:-}" ]] && kill "$SAFETY_HEARTBEAT_PID" 2>/dev/null; [[ "$ORDER_CACHE_IS_FALLBACK" == "1" ]] && rm -f "$ORDER_CACHE_FILE"' EXIT

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

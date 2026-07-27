#!/usr/bin/env bash
# Ridge memory plugin: a memory usage bar-block glyph with threshold color,
# plus a top-memory-processes popup. Split out of the former sysmon plugin
# (which bracketed cpu+memory together) so memory is its own installable
# widget. See README.md. Talks to ridge over $RIDGE_SOCKET via the `ridge`
# CLI.
set -uo pipefail

ITEM_ID="memory.usage"

_have() { command -v "$1" >/dev/null 2>&1; }

# `timeout` isn't shipped on macOS by default; alarm+exec is the standard
# shim (matches the sibling tasks/raycast_focus plugins). Bounds the
# `ridge query items` popup-open check so a hung socket can never stall the
# poll loop.
_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# shellcheck disable=SC2034 # SETTING_* are consumed by main(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  # Placement default only - ridge.yaml's plugins[].region and
  # plugins[].items override it. Not a user setting.
  SETTING_region="right"
  # Icon font: the memory bar-block glyph is set via `ridge set --icon` in the
  # poll loop; a Nerd Font family must be set at `ridge add` time so glyphs
  # set later don't render as tofu in the system default font.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  # Poll interval in seconds; also the popup process-row refresh cadence while
  # the popup is open. Must be a positive number, else default 5 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "5"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="5"
  SETTING_warn_threshold="$(jq -r '.warn_threshold // "75"' <<<"$json")"
  [[ "$SETTING_warn_threshold" =~ ^[0-9]+$ && "$SETTING_warn_threshold" -ge 1 && "$SETTING_warn_threshold" -le 100 ]] || SETTING_warn_threshold="75"
  SETTING_crit_threshold="$(jq -r '.crit_threshold // "90"' <<<"$json")"
  [[ "$SETTING_crit_threshold" =~ ^[0-9]+$ && "$SETTING_crit_threshold" -ge 1 && "$SETTING_crit_threshold" -le 100 ]] || SETTING_crit_threshold="90"
  SETTING_mem_color="$(jq -r '.mem_color // "theme:media"' <<<"$json")"
  SETTING_warn_color="$(jq -r '.warn_color // "theme:warning"' <<<"$json")"
  SETTING_crit_color="$(jq -r '.crit_color // "theme:error"' <<<"$json")"
  # Pill background, matching battery/aerospace's bubbles.
  SETTING_bg_color="$(jq -r '.bg_color // "theme:background"' <<<"$json")"
  SETTING_corner_radius="$(jq -r '.corner_radius // ""' <<<"$json")"
  if [[ -n "$SETTING_corner_radius" ]] && ! [[ "$SETTING_corner_radius" =~ ^[0-9]+$ && "$SETTING_corner_radius" -ge 0 && "$SETTING_corner_radius" -le 30 ]]; then
    SETTING_corner_radius=""
  fi
  # Empty (unset) means auto: ridge core adapts the pill height to the bar
  # height. bg_height stays a valid opt-in override; out-of-range or
  # non-numeric input resets to empty/auto rather than any fixed default.
  SETTING_bg_height="$(jq -r '.bg_height // ""' <<<"$json")"
  if [[ -n "$SETTING_bg_height" ]] && ! [[ "$SETTING_bg_height" =~ ^[0-9]+$ && "$SETTING_bg_height" -ge 16 && "$SETTING_bg_height" -le 48 ]]; then
    SETTING_bg_height=""
  fi
}

# 8-level vertical bar-block glyph: idx = floor((pct*8+99)/100), clamped 1-8.
_mem_bar_char() {
  local pct="$1" idx
  idx=$(( (pct * 8 + 99) / 100 ))
  (( idx < 1 )) && idx=1
  (( idx > 8 )) && idx=8
  case "$idx" in
    1) printf '▁' ;; 2) printf '▂' ;; 3) printf '▃' ;; 4) printf '▄' ;;
    5) printf '▅' ;; 6) printf '▆' ;; 7) printf '▇' ;; *) printf '█' ;;
  esac
}

# Threshold color: >= crit_threshold -> crit_color, >= warn_threshold ->
# warn_color, else mem_color.
_mem_color() {
  local pct="$1" warn_threshold="$2" crit_threshold="$3" warn_color="$4" crit_color="$5" healthy_color="$6"
  if [[ "$pct" -ge "$crit_threshold" ]]; then
    printf '%s' "$crit_color"
  elif [[ "$pct" -ge "$warn_threshold" ]]; then
    printf '%s' "$warn_color"
  else
    printf '%s' "$healthy_color"
  fi
}

# Memory% (0-100) from `vm_stat` output: (active + wired + compressor pages)
# * pagesize / total * 100, rounded.
_mem_pct() {
  local vm_stat_out="$1" total="$2" pagesize="$3"
  printf '%s\n' "$vm_stat_out" | awk -v total="$total" -v ps="$pagesize" '
    /Pages active/                 { gsub(/\./, "", $3); active = $3 }
    /Pages wired down/             { gsub(/\./, "", $4); wired = $4 }
    /Pages occupied by compressor/ { gsub(/\./, "", $5); comp = $5 }
    END { if (total > 0) printf "%d", (active + wired + comp) * ps / total * 100 + 0.5 }'
}

# RSS (KB) -> human size: "X.XG" at/above 1GiB (1048576 KB), else "XM".
_mem_fmt() {
  local kb="$1"
  awk -v k="$kb" 'BEGIN { if (k >= 1048576) printf "%.1fG", k/1048576; else printf "%dM", (k+512)/1024 }'
}

# Builds the single-column popup JSON from "<sizeText>\t<name>" lines
# (already top-10, descending). Collected via jq -n --arg per line then
# folded with jq -s (tasks.sh's pattern), so a hostile process name can never
# break the JSON payload or the jq program.
_mem_popup_rows_json() {
  local lines="$1" pct="${2:-}" total="${3:-}"
  local -a items=()
  local val name
  while IFS=$'\t' read -r val name; do
    [[ -z "$val" ]] && continue
    items+=("$(jq -n --arg val "$val" --arg name "$name" '{icon: $val, text: $name}')")
  done <<<"$lines"
  local rows_json="[]"
  if [[ "${#items[@]}" -gt 0 ]]; then
    rows_json="$(printf '%s\n' "${items[@]}" | jq -s '.')"
  fi
  # A single header line carries the summary - see the cpu plugin for why a
  # separate summary row read badly (two stacked headers, orphaned number).
  local head
  if [[ "$pct" =~ ^[0-9]+$ ]]; then
    if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
      local total_kb=$(( total / 1024 ))
      local used_kb=$(( total_kb * pct / 100 ))
      head="Memory  ${pct}%  ·  $(_mem_fmt "$used_kb") / $(_mem_fmt "$total_kb")"
    else
      head="Memory  ${pct}% used"
    fi
  else
    head="Memory  ·  measuring..."
  fi
  jq -n --arg head "$head" --argjson rows "$rows_json" \
    '[{type: "header", text: $head}] + $rows'
}

# Top-10 processes by memory (ps's own -m sort), "<sizeText>\t<comm>" lines.
# The RSS->size formula is inlined here (awk can't call the bash _mem_fmt
# helper) but is kept identical to it; _mem_fmt is the unit-tested source of
# truth for that formula.
_mem_top_lines() {
  ps -Aceo pmem,rss,comm -m 2>/dev/null | sed -n '2,11p' | awk '{
    rss = $2; comm = $3; for (i = 4; i <= NF; i++) comm = comm " " $i
    if (rss >= 1048576) { printf "%.1fG\t%s\n", rss / 1048576, comm }
    else { printf "%dM\t%s\n", (rss + 512) / 1024, comm }
  }'
}

# True when the popup is currently open, via `ridge query items`'s
# popupOpen field.
_mem_popup_open() {
  local open
  open="$(_timeout 3 ridge query items 2>/dev/null | jq -r --arg id "$ITEM_ID" '(.[] | select(.id == $id) | .popupOpen) // false' 2>/dev/null)"
  [[ "$open" == "true" ]]
}

# Pill background flags for the item's `ridge add` call -
# extracted so bats can assert the flags without invoking the real `ridge`
# CLI. Set once at add time: later `ridge set` calls only touch icon/color,
# and an item's background/padding persists across those.
_pill_flags() {
  local out
  out="$(printf -- '--bg-color %s' "$SETTING_bg_color")"
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- ' --bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

main() {
  for dep in jq ridge; do
    if ! _have "$dep"; then echo "memory: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "memory: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors/numbers only)
  # Seed an icon part (`--icon " "`) and empty text: the poll loop shows the
  # usage bar as the item's ICON via `ridge set --icon`, which needs an icon
  # part to exist; and `ridge add` requires `--text` for a static item, so
  # without both the add failed validation and every later set errored
  # "unknown item id". Text stays empty - the bar char is the whole display.
  ridge add "$ITEM_ID" --region "$SETTING_region" --icon " " --text "" --icon-color "$SETTING_mem_color" --font "$SETTING_font" --click "ridge popup toggle $ITEM_ID" $(_pill_flags) || true
  # Seed the popup rows once so the item gains a popup spec and its click
  # (`popup toggle`) can actually open it. The in-loop refresh below only runs
  # while the popup is open; without this seed the item never gets a spec and
  # `popup toggle` no-ops.
  ridge popup set-rows "$ITEM_ID" --json "$(_mem_popup_rows_json "$(_mem_top_lines)")" 2>/dev/null || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    local total pagesize mem_out mem_pct
    total="$(sysctl -n hw.memsize 2>/dev/null)"
    pagesize="$(sysctl -n hw.pagesize 2>/dev/null)"
    mem_out="$(vm_stat 2>/dev/null)"
    mem_pct="$(_mem_pct "$mem_out" "${total:-0}" "${pagesize:-0}")"
    if [[ "$mem_pct" =~ ^[0-9]+$ ]]; then
      local color
      color="$(_mem_color "$mem_pct" "$SETTING_warn_threshold" "$SETTING_crit_threshold" "$SETTING_warn_color" "$SETTING_crit_color" "$SETTING_mem_color")"
      ridge set "$ITEM_ID" --icon "$(_mem_bar_char "$mem_pct")" --icon-color "$color" 2>/dev/null || true
    fi

    # Process listing is relatively expensive - only sample/refresh it while
    # the popup is actually open, at the plugin's normal interval cadence.
    if _mem_popup_open; then
      local rows_json
      rows_json="$(_mem_popup_rows_json "$(_mem_top_lines)" "$mem_pct" "${total:-0}")"
      ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
    fi

    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so the
# guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

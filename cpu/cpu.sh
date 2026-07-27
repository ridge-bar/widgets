#!/usr/bin/env bash
# Ridge cpu plugin: a CPU usage bar-block glyph with threshold color, plus a
# top-CPU-processes popup. Split out of the former sysmon plugin (which
# bracketed cpu+memory together) so cpu is its own installable widget. Ported
# from sketchybar's items/sysmon.sh + plugins/cpu.sh + plugins/sysmon_popup.sh
# + plugins/usage_bar.sh. See README.md. Talks to ridge over $RIDGE_SOCKET via
# the `ridge` CLI.
set -uo pipefail

ITEM_ID="cpu.usage"

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
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  # Icon font: the CPU bar-block glyph is set via `ridge set --icon` in the
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
  SETTING_cpu_color="$(jq -r '.cpu_color // "theme:system"' <<<"$json")"
  SETTING_warn_color="$(jq -r '.warn_color // "theme:warning"' <<<"$json")"
  SETTING_crit_color="$(jq -r '.crit_color // "theme:error"' <<<"$json")"
  # Sketchybar-style pill background, matching battery/aerospace's bubbles.
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

# State directory for the per-process CPU-delta snapshot (mindfulness's
# XDG_STATE_HOME convention - this is a refresh cache, not click-mutated
# state).
_cpu_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/cpu"
  mkdir -p "$dir" && chmod 0700 "$dir"
  printf '%s' "$dir"
}

# 8-level vertical bar-block glyph (bar_char() from sketchybar's
# usage_bar.sh, ported verbatim): idx = floor((pct*8+99)/100), clamped 1-8.
_cpu_bar_char() {
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
# warn_color, else cpu_color.
_cpu_color() {
  local pct="$1" warn_threshold="$2" crit_threshold="$3" warn_color="$4" crit_color="$5" healthy_color="$6"
  if [[ "$pct" -ge "$crit_threshold" ]]; then
    printf '%s' "$crit_color"
  elif [[ "$pct" -ge "$warn_threshold" ]]; then
    printf '%s' "$warn_color"
  else
    printf '%s' "$healthy_color"
  fi
}

# CPU% (0-100) from `iostat -c 2 -w 1` output: sum of the final line's us+sy
# columns, rounded.
#
# Counted from the END of the line, not fixed positions: iostat prints three
# columns per disk, so us/sy land at $4/$5 only on a single-disk machine. With
# more disks those positions are a disk's KB/t and tps (usually 0), which made
# CPU read 0 and the bar freeze at its lowest block. The trailing fields are
# always `us sy id 1m 5m 15m`, so us=$(NF-5) and sy=$(NF-4) hold for any disk
# count.
# 1-minute load average: the last three fields of an iostat line are
# `1m 5m 15m`, so it sits at $(NF-2) whatever the disk count.
_cpu_load() {
  printf '%s\n' "$1" | awk 'END { printf "%s", $(NF-2) }'
}

_cpu_pct() {
  local iostat_out="$1"
  printf '%s\n' "$iostat_out" | awk 'END { printf "%d", $(NF-5) + $(NF-4) + 0.5 }'
}

# Parses a `ps cputime` field (H:MM:SS, MM:SS, or SS) into total seconds.
# Ported verbatim from sketchybar's sysmon_popup.sh tosec() awk function.
_cpu_tosec() {
  local t="$1"
  awk -v t="$t" 'BEGIN {
    n = split(t, a, ":")
    if (n == 3) print a[1] * 3600 + a[2] * 60 + a[3]
    else if (n == 2) print a[1] * 60 + a[2]
    else print a[1]
  }'
}

# Instantaneous per-process CPU%: (cs_now - cs_prev) / dt * 100, clamped at 0;
# falls back to `pcpu` (ps's lifetime average) when dt is stale/first-frame
# (dt <= 0 || dt > 10). This is the btop-style delta the sketchybar source
# uses instead of ps's pcpu, which overstates processes busy long ago and
# understates ones spiking right now.
_cpu_delta_pct() {
  local cs_now="$1" cs_prev="$2" dt="$3" pcpu="$4"
  if awk -v dt="$dt" 'BEGIN { exit !(dt <= 0 || dt > 10) }'; then
    printf '%s' "$pcpu"
    return
  fi
  awk -v now="$cs_now" -v prev="$cs_prev" -v dt="$dt" 'BEGIN {
    d = (now - prev) / dt * 100
    if (d < 0) d = 0
    printf "%.1f", d
  }'
}

# Builds the single-column popup JSON from "<pct>\t<name>" lines (already
# top-10, descending). Collected via jq -n --arg per line then folded with
# jq -s (tasks.sh's pattern), so a hostile process name can never break the
# JSON payload or the jq program.
_cpu_popup_rows_json() {
  local lines="$1" pct="${2:-}" load="${3:-}"
  local -a items=()
  local val name
  while IFS=$'\t' read -r val name; do
    [[ -z "$val" ]] && continue
    items+=("$(jq -n --arg val "$val" --arg name "$name" '{icon: ($val + "%"), text: $name}')")
  done <<<"$lines"
  local rows_json="[]"
  if [[ "${#items[@]}" -gt 0 ]]; then
    rows_json="$(printf '%s\n' "${items[@]}" | jq -s '.')"
  fi
  # A single header line carries the summary: a separate summary row plus a
  # "Top CPU" header stacked two headers on top of each other and left the
  # percentage orphaned in the icon column, away from its own label.
  local head
  if [[ "$pct" =~ ^[0-9]+$ ]]; then
    head="CPU  ${pct}% used"
    [[ -n "$load" ]] && head="$head  ·  load $load"
  else
    head="CPU  ·  measuring..."
  fi
  jq -n --arg head "$head" --argjson rows "$rows_json" \
    '[{type: "header", text: $head}] + $rows'
}

# Samples top-10 per-process CPU via the delta algorithm above, persisting
# the pid->cputime snapshot atomically (temp+mv) under the cpu state dir.
# Prints "<pct>\t<comm>" lines, descending. Ported verbatim (algorithm) from
# sketchybar's sysmon_popup.sh; only the snapshot location and atomic write
# are new.
_cpu_top_lines() {
  local dir snap snap_tmp nowt prevt dt out
  dir="$(_cpu_state_dir)"
  snap="${dir}/cpu_snap"
  snap_tmp="${snap}.tmp.$$"
  nowt="$(date +%s)"
  prevt="$(head -1 "$snap" 2>/dev/null)"
  [[ "$prevt" =~ ^[0-9]+$ ]] || prevt=0
  dt=$((nowt - prevt))
  out="$(ps -Aceo pid=,cputime=,pcpu=,comm= 2>/dev/null | awk -v dt="$dt" -v nowt="$nowt" -v snap="$snap" -v snap_tmp="$snap_tmp" '
    function tosec(t,   n, a) {
      n = split(t, a, ":")
      if (n == 3) return a[1] * 3600 + a[2] * 60 + a[3]
      if (n == 2) return a[1] * 60 + a[2]
      return a[1]
    }
    BEGIN {
      stale = (dt <= 0 || dt > 10)
      while ((getline l < snap) > 0) {
        if (++ln == 1) continue
        split(l, p, " "); prev[p[1]] = p[2]
      }
      close(snap)
      print nowt > snap_tmp
    }
    {
      pid = $1; cs = tosec($2); pcpu = $3
      comm = $4; for (i = 5; i <= NF; i++) comm = comm " " $i
      print pid, cs >> snap_tmp
      if (!stale && (pid in prev)) {
        d = (cs - prev[pid]) / dt * 100
        if (d < 0) d = 0
      } else d = pcpu
      printf "%.1f\t%s\n", d, comm
    }
  ' | sort -rn -k1 | head -10)"
  mv -f "$snap_tmp" "$snap" 2>/dev/null || rm -f "$snap_tmp"
  printf '%s\n' "$out"
}

# True when the popup is currently open, via `ridge query items`'s
# popupOpen field.
_cpu_popup_open() {
  local open
  open="$(_timeout 3 ridge query items 2>/dev/null | jq -r --arg id "$ITEM_ID" '(.[] | select(.id == $id) | .popupOpen) // false' 2>/dev/null)"
  [[ "$open" == "true" ]]
}

# Sketchybar-style pill background flags for the item's `ridge add` call -
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
    if ! _have "$dep"; then echo "cpu: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "cpu: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors/numbers only)
  # Seed an icon part (`--icon " "`) and empty text: the poll loop shows the
  # usage bar as the item's ICON via `ridge set --icon`, which needs an icon
  # part to exist; and `ridge add` requires `--text` for a static item, so
  # without both the add failed validation and every later set errored
  # "unknown item id". Text stays empty - the bar char is the whole display.
  ridge add "$ITEM_ID" --region "$SETTING_region" --icon " " --text "" --icon-color "$SETTING_cpu_color" --font "$SETTING_font" --click "ridge popup toggle $ITEM_ID" $(_pill_flags) || true
  # Seed the popup rows once so the item gains a popup spec and its click
  # (`popup toggle`) can actually open it. The in-loop refresh below only runs
  # while the popup is open; without this seed the item never gets a spec and
  # `popup toggle` no-ops. Seeding also primes the CPU snapshot so the first
  # real refresh has a valid delta.
  ridge popup set-rows "$ITEM_ID" --json "$(_cpu_popup_rows_json "$(_cpu_top_lines)")" 2>/dev/null || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    local cpu_out cpu_pct
    cpu_out="$(iostat -c 2 -w 1 2>/dev/null)"
    cpu_pct="$(_cpu_pct "$cpu_out")"
    if [[ "$cpu_pct" =~ ^[0-9]+$ ]]; then
      local color
      color="$(_cpu_color "$cpu_pct" "$SETTING_warn_threshold" "$SETTING_crit_threshold" "$SETTING_warn_color" "$SETTING_crit_color" "$SETTING_cpu_color")"
      ridge set "$ITEM_ID" --icon "$(_cpu_bar_char "$cpu_pct")" --icon-color "$color" 2>/dev/null || true
    fi

    # Process listing is relatively expensive - only sample/refresh it while
    # the popup is actually open, at the plugin's normal interval cadence.
    if _cpu_popup_open; then
      local rows_json
      rows_json="$(_cpu_popup_rows_json "$(_cpu_top_lines)" "$cpu_pct" "$(_cpu_load "$cpu_out")")"
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

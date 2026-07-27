#!/usr/bin/env bash
# Ridge claude plugin: an icon that tints green while any Claude Code session
# is mid-turn or a subagent is running, plus a details popup listing active
# sessions, live subagents, and token usage over 5h/24h/7d windows (see
# README.md). Talks to ridge over $RIDGE_SOCKET via the `ridge` CLI.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEM_ID="claude.status"
CLAUDE_GLYPH="󰚩"
# Fixed accent for the popup's title row.
# Not user-configurable - a fixed accent, not a threshold color (mirrors
# battery.sh's BATTERY_TITLE_COLOR / weather.sh's WEATHER_TITLE_COLOR).
CLAUDE_TITLE_COLOR="#FF9E64"

_have() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC2034 # SETTING_* are consumed by main()/paint helpers, not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  # Icon font: CLAUDE_GLYPH is a Nerd Font glyph, so it renders as tofu in
  # the system default font unless a Nerd Font family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  # Poll interval in seconds. Must be a positive number, else default 10 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "10"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="10"

  # projects_dir defaults to a path built from $HOME, which YAML cannot
  # expand as a literal string in plugin.yaml. So plugin.yaml leaves this
  # unset (jq lookup yields "" via the // fallback below) and the
  # bash-expanded default is applied here instead, same convention as
  # tasks.sh's noteplan_dir/obsidian_inbox_dir.
  SETTING_projects_dir="$(jq -r '.projects_dir // ""' <<<"$json")"
  [[ -n "$SETTING_projects_dir" ]] || SETTING_projects_dir="${HOME}/.claude/projects"

  # `pgrep -f` match string for a running Claude Code CLI process. The
  # default is specific to that user's install path - exposed as a setting so
  # other installs (e.g. an npm-global `claude`) can override it.
  SETTING_process_pattern="$(jq -r '.process_pattern // "local/bin/claude"' <<<"$json")"
  [[ -n "$SETTING_process_pattern" ]] || SETTING_process_pattern="local/bin/claude"

  SETTING_idle_icon_color="$(jq -r '.idle_icon_color // "theme:warning"' <<<"$json")"
  SETTING_busy_icon_color="$(jq -r '.busy_icon_color // "#12161D"' <<<"$json")"
  SETTING_idle_bg_color="$(jq -r '.idle_bg_color // "theme:background"' <<<"$json")"
  SETTING_busy_bg_color="$(jq -r '.busy_bg_color // "theme:success"' <<<"$json")"
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
  SETTING_max_sessions="$(jq -r '.max_sessions // "5"' <<<"$json")"
  [[ "$SETTING_max_sessions" =~ ^[0-9]+$ && "$SETTING_max_sessions" -ge 1 && "$SETTING_max_sessions" -le 10 ]] || SETTING_max_sessions="5"
  SETTING_max_subagents="$(jq -r '.max_subagents // "4"' <<<"$json")"
  [[ "$SETTING_max_subagents" =~ ^[0-9]+$ && "$SETTING_max_subagents" -ge 1 && "$SETTING_max_subagents" -le 10 ]] || SETTING_max_subagents="4"
  SETTING_cache_stale_seconds="$(jq -r '.cache_stale_seconds // "300"' <<<"$json")"
  [[ "$SETTING_cache_stale_seconds" =~ ^[0-9]+$ && "$SETTING_cache_stale_seconds" -ge 30 && "$SETTING_cache_stale_seconds" -le 3600 ]] || SETTING_cache_stale_seconds="300"
}

##############################################################################
# Pure parsing/formatting/decision functions: no I/O beyond `jq`/`awk`
# subprocesses fed explicit arguments - callers pass already-read data, so
# these are directly testable against fixtures without invoking `ridge`,
# `find`, or the real Python helpers (see tests/rows.bats, tests/pure.bats).
##############################################################################

# agent-<id>.jsonl path -> first 8 chars of <id>, via parameter expansion.
_claude_agent_short_id() {
  local path="$1" fname id
  fname="${path##*/}"
  fname="${fname%.jsonl}"
  id="${fname#agent-}"
  printf '%s' "${id:0:8}"
}

# busy when working=="1" or any live subagent is present, else idle.
_claude_working_state() {
  local working="$1" subagent_count="$2"
  if [[ "${working:-0}" == "1" || "${subagent_count:-0}" -gt 0 ]]; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

# Pure staleness check: true (status 0) when an item aged `age_seconds` is
# older than `stale_seconds`, or when age_seconds is negative (the I/O
# wrapper's signal for "cache file absent").
_claude_cache_age_stale() {
  local age_seconds="$1" stale_seconds="$2"
  [[ "$age_seconds" -lt 0 ]] && return 0
  [[ "$age_seconds" -gt "$stale_seconds" ]]
}

# Session rows (state<TAB>project<TAB>ago lines from claude_sessions.py) ->
# JSON row array, capped at `max`. working -> green dot, waiting -> orange dot.
_claude_session_rows_json() {
  local data="$1" max="$2" green="$3" orange="$4"
  local -a items=()
  local n=0 state project ago
  while IFS=$'\t' read -r state project ago; do
    [[ -z "$state$project$ago" ]] && continue
    n=$((n + 1))
    [[ "$n" -gt "$max" ]] && break
    local dot col
    if [[ "$state" == "working" ]]; then dot="●"; col="$green"; else dot="○"; col="$orange"; fi
    items+=("$(jq -n --arg icon "$dot" --arg color "$col" --arg text "${project}  ·  ${ago}" \
      '{icon: $icon, icon_color: $color, text: $text}')")
  done <<<"$data"
  if [[ "${#items[@]}" -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${items[@]}" | jq -s '.'
  fi
}

# Live subagent transcript paths (one per line) -> JSON row array, capped at
# `max`. Every row is a green dot with "agent <8-char-id>".
_claude_subagent_rows_json() {
  local paths="$1" max="$2" green="$3"
  local -a items=()
  local n=0 apath id
  while IFS= read -r apath; do
    [[ -z "$apath" ]] && continue
    n=$((n + 1))
    [[ "$n" -gt "$max" ]] && break
    id="$(_claude_agent_short_id "$apath")"
    items+=("$(jq -n --arg color "$green" --arg text "agent ${id}" \
      '{icon: "●", icon_color: $color, text: $text}')")
  done <<<"$paths"
  if [[ "${#items[@]}" -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${items[@]}" | jq -s '.'
  fi
}

# Builds the full popup rows JSON via `jq -n --arg`/`--argjson` (not string
# splicing): title row, session rows, subagent rows, then 3 token rows.
_claude_popup_rows_json() {
  local sessions_json="$1" subagents_json="$2" tok5h="$3" tok24h="$4" tok7d="$5"
  jq -n \
    --arg title_color "$CLAUDE_TITLE_COLOR" \
    --argjson sessions "$sessions_json" \
    --argjson subagents "$subagents_json" \
    --arg tok5h "$tok5h" \
    --arg tok24h "$tok24h" \
    --arg tok7d "$tok7d" \
    '[{icon: "Claude Code", text: "", color: $title_color, icon_color: $title_color}]
     + $sessions + $subagents +
     [
       {icon: "Tokens · 5h", text: $tok5h},
       {icon: "Tokens · 24h", text: $tok24h},
       {icon: "Tokens · 7d", text: $tok7d}
     ]'
}

# Pill background flags for the item's `ridge add` call - extracted so bats
# can assert the flags without invoking the real `ridge` CLI.
_pill_flags() {
  local out
  out="$(printf -- '--bg-color %s' "$SETTING_idle_bg_color")"
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- ' --bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

##############################################################################
# I/O: talks to the filesystem, the vendored Python helpers, and ridge.
##############################################################################

_claude_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/claude"
  mkdir -p "$dir" && chmod 0700 "$dir"
  printf '%s' "$dir"
}

# True (status 0) when $file is missing or older than $stale_seconds.
_claude_cache_stale() {
  local file="$1" stale_seconds="$2" mtime now age
  [[ -f "$file" ]] || return 0
  mtime="$(stat -f %m "$file" 2>/dev/null)" || return 0
  now="$(date +%s)"
  age=$(( now - mtime ))
  _claude_cache_age_stale "$age" "$stale_seconds"
}

# Recomputes the 24h/7d token caches in the background when stale, guarded by
# a mkdir-based lock (atomic - `mkdir` fails if the directory already exists)
# so an overlapping refresh never stacks a second one on top of a slow one.
# Same tmp+mv atomic-write convention as mindfulness.sh's _state_write /
# weather.sh's _refresh_cache.
_claude_maybe_refresh_token_cache() {
  local projects_dir="$1" state_dir="$2" dcache="$3" wcache="$4" stale_seconds="$5"
  _claude_cache_stale "$wcache" "$stale_seconds" || return 0
  local lock="${state_dir}/refresh.lock"
  mkdir "$lock" 2>/dev/null || return 0
  (
    trap 'rmdir "'"$lock"'" 2>/dev/null' EXIT
    local dtmp wtmp
    dtmp="${dcache}.tmp.$$"
    wtmp="${wcache}.tmp.$$"
    find "$projects_dir" -name '*.jsonl' -mmin -1440 2>/dev/null \
      | python3 "${PLUGIN_ROOT}/claude_tokens.py" 86400 > "$dtmp" && mv -f "$dtmp" "$dcache"
    find "$projects_dir" -name '*.jsonl' -mmin -10080 2>/dev/null \
      | python3 "${PLUGIN_ROOT}/claude_tokens.py" 604800 > "$wtmp" && mv -f "$wtmp" "$wcache"
  ) >/dev/null 2>&1 &
}

# One poll tick: paint the bar item (icon color + background) and rebuild the
# popup rows.
_claude_poll_and_paint() {
  local projects_dir="$SETTING_projects_dir"

  local sessions
  sessions="$(pgrep -f "$SETTING_process_pattern" 2>/dev/null | wc -l | tr -d ' ')"

  local subagent_paths subagent_count
  subagent_paths="$(find "$projects_dir" -path '*/subagents/agent-*.jsonl' -mmin -1 2>/dev/null)"
  subagent_count="$(printf '%s\n' "$subagent_paths" | grep -c . 2>/dev/null)"; subagent_count=${subagent_count:-0}

  local working
  working="$(find "$projects_dir" -name '*.jsonl' -not -path '*/subagents/*' -mmin -720 2>/dev/null \
    | python3 "${PLUGIN_ROOT}/claude_working.py" "${sessions:-0}")"

  local state bg icon_color
  state="$(_claude_working_state "$working" "$subagent_count")"
  if [[ "$state" == "busy" ]]; then
    bg="$SETTING_busy_bg_color"; icon_color="$SETTING_busy_icon_color"
  else
    bg="$SETTING_idle_bg_color"; icon_color="$SETTING_idle_icon_color"
  fi
  ridge set "$ITEM_ID" --icon-color "$icon_color" --bg-color "$bg" 2>/dev/null || true

  local session_data sessions_json subagents_json
  session_data="$(find "$projects_dir" -name '*.jsonl' -not -path '*/subagents/*' -mmin -720 2>/dev/null \
    | python3 "${PLUGIN_ROOT}/claude_sessions.py" "${sessions:-0}")"
  sessions_json="$(_claude_session_rows_json "$session_data" "$SETTING_max_sessions" "$SETTING_busy_bg_color" "$SETTING_idle_icon_color")"
  subagents_json="$(_claude_subagent_rows_json "$subagent_paths" "$SETTING_max_subagents" "$SETTING_busy_bg_color")"

  # 5h is cheap -> compute fresh every tick.
  local tok5h
  tok5h="$(find "$projects_dir" -name '*.jsonl' -mmin -300 2>/dev/null | python3 "${PLUGIN_ROOT}/claude_tokens.py" 18000)"
  [[ -z "$tok5h" ]] && tok5h="0"

  # 24h / 7d -> serve cached values, refresh in the background if stale.
  local state_dir dcache wcache tok24h tok7d
  state_dir="$(_claude_state_dir)"
  dcache="${state_dir}/daily"
  wcache="${state_dir}/weekly"
  tok24h="$(cat "$dcache" 2>/dev/null)"; [[ -z "$tok24h" ]] && tok24h="…"
  tok7d="$(cat "$wcache" 2>/dev/null)"; [[ -z "$tok7d" ]] && tok7d="…"
  _claude_maybe_refresh_token_cache "$projects_dir" "$state_dir" "$dcache" "$wcache" "$SETTING_cache_stale_seconds"

  local rows_json
  rows_json="$(_claude_popup_rows_json "$sessions_json" "$subagents_json" "$tok5h" "$tok24h" "$tok7d")"
  ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
}

main() {
  for dep in jq python3 ridge; do
    if ! _have "$dep"; then echo "claude: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "claude: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors/numbers only)
  ridge add "$ITEM_ID" --region "$SETTING_region" --text "" --icon "$CLAUDE_GLYPH" --icon-color "$SETTING_idle_icon_color" --click "ridge popup toggle $ITEM_ID" --font "$SETTING_font" $(_pill_flags) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    _claude_poll_and_paint
    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so the
# guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

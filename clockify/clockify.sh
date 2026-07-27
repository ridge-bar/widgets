#!/usr/bin/env bash
# Ridge clockify plugin: a bar item reflecting Clockify time-tracking status
# (green=tracking, orange=idle), left-click toggles start/stop, right-click
# opens a popup with the current task (click to stop), app/calendar/reports
# shortcuts, and recent tasks (click to resume). Ported from sketchybar's
# items/clockify.sh + plugins/clockify*.sh (see README.md). Talks to ridge
# over $RIDGE_SOCKET via the `ridge` CLI.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEM_ID="clockify.status"
CLOCKIFY_API="https://api.clockify.me/api/v1"
# Nerd Font stopwatch glyph, matching the sketchybar source's icon=󰔛. Ridge
# only attaches an icon PART to an item if --icon carries a non-empty value
# at `ridge add` time - see tasks.sh/README.md.
CLOCKIFY_ICON="󰔛"

_have() { command -v "$1" >/dev/null 2>&1; }

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this script's
# own eval; the click's env assignment, script path, and settings path must
# survive both.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Builds a self-reinvoke click command: re-exec this script with the given
# env var assignment set (plus RIDGE_PLUGIN_SETTINGS forwarded via shq), so a
# row click runs an action and repaints without waiting for the next poll.
build_reexec_cmd() {
  local env_assignment="$1" script_path="$2" settings_path="${3:-}"
  local out="$env_assignment"
  if [[ -n "$settings_path" ]]; then
    out="RIDGE_PLUGIN_SETTINGS=$(shq "$settings_path") ${out}"
  fi
  printf '%s %s' "$out" "$(shq "$script_path")"
}

# shellcheck disable=SC2034 # SETTING_* consumed by main()/paint/click handlers, not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  # Icon font: CLOCKIFY_ICON is a Nerd Font glyph, so it renders as tofu in
  # the system default font unless a Nerd Font family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  # Poll interval in seconds. Must be a positive number, else default 30 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "30"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="30"

  # token_file defaults to a $HOME-expanded path, which YAML cannot express
  # as a literal default in plugin.yaml (see tasks.sh's noteplan_dir for the
  # same technique). plugin.yaml leaves this unset (jq // fallback yields
  # "") and the bash-expanded default is applied here instead - chosen so an
  # existing sketchybar `.clockify_token` file keeps working unmodified.
  SETTING_token_file="$(jq -r '.token_file // ""' <<<"$json")"
  [[ -n "$SETTING_token_file" ]] || SETTING_token_file="${HOME}/.config/sketchybar/.clockify_token"

  SETTING_max_rows="$(jq -r '.max_rows // "10"' <<<"$json")"
  [[ "$SETTING_max_rows" =~ ^[0-9]+$ && "$SETTING_max_rows" -ge 1 && "$SETTING_max_rows" -le 10 ]] || SETTING_max_rows="10"
  # The API key is passed via a curl config on a process-substitution fd (-K),
  # never in argv, so it is not visible to other local processes via ps.
  # curl --max-time in seconds. A hung request must never stall the poll loop
  # or a click - always bounded, never an unbounded curl.
  SETTING_request_timeout="$(jq -r '.request_timeout // "8"' <<<"$json")"
  [[ "$SETTING_request_timeout" =~ ^[0-9]+$ && "$SETTING_request_timeout" -ge 3 && "$SETTING_request_timeout" -le 30 ]] || SETTING_request_timeout="8"

  SETTING_tracking_color="$(jq -r '.tracking_color // "theme:success"' <<<"$json")"
  SETTING_idle_color="$(jq -r '.idle_color // "theme:warning"' <<<"$json")"
  SETTING_warn_color="$(jq -r '.warn_color // "theme:secondary"' <<<"$json")"
  SETTING_icon_color="$(jq -r '.icon_color // "#12161D"' <<<"$json")"
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

##############################################################################
# Pure parsing/formatting functions: no I/O - callers pass explicit values so
# these are directly testable against fixtures (see tests/rows.bats,
# tests/pure.bats).
##############################################################################

# Strips all whitespace (including newlines) from a raw token-file read,
# mirroring the sketchybar source's `tr -d '[:space:]' < "$TOKEN_FILE"`.
_clockify_clean_token() {
  local raw="$1"
  printf '%s' "$raw" | tr -d '[:space:]'
}

# RUNNING -> tracking_color, anything else -> idle_color.
_clockify_state_color() {
  local state="$1" tracking_color="$2" idle_color="$3"
  if [[ "$state" == "RUNNING" ]]; then
    printf '%s' "$tracking_color"
  else
    printf '%s' "$idle_color"
  fi
}

# True (status 0) when idx is a valid, in-range index into a $count-length
# array. Defensive bounds check for the "start by index" popup click, even
# though the jq lookup that follows already no-ops on an out-of-range index.
_clockify_index_in_range() {
  local idx="$1" count="$2"
  [[ "$idx" =~ ^[0-9]+$ && "$idx" -ge 0 && "$idx" -lt "$count" ]]
}

# Builds a Clockify POST body ({start, description, projectId?, taskId?,
# tagIds?}) from a cached history entry's JSON, ported from the sketchybar
# source's clockify_start.sh Python heredoc. entry_json must be a single JSON
# object (as extracted from the cache's history[] array).
_clockify_resume_body_json() {
  local entry_json="$1" now="$2"
  jq -n --argjson e "$entry_json" --arg now "$now" '
    {start: $now, description: ($e.description // "")}
    + (if ($e.projectId // null) != null then {projectId: $e.projectId} else {} end)
    + (if ($e.taskId // null) != null then {taskId: $e.taskId} else {} end)
    + (if ($e.tagIds // []) != [] then {tagIds: $e.tagIds} else {} end)
  '
}

# Builds the full popup rows JSON via `jq -n --arg` (not string splicing):
# current task, open desktop/calendar/reports, then up to max_rows recent
# tasks. Every click goes through build_reexec_cmd/shq so it survives ridge's
# `/bin/sh -c` execution layer.
_clockify_popup_rows_json() {
  local current_label="$1" max_rows="$2"
  shift 2
  local -a recent=("$@")
  local script_path="${PLUGIN_ROOT}/clockify.sh" settings_path="${RIDGE_PLUGIN_SETTINGS:-}"
  local current_click desktop_click calendar_click reports_click
  current_click="$(build_reexec_cmd "CLOCKIFY_ACTION=stop" "$script_path" "$settings_path")"
  desktop_click="$(build_reexec_cmd "CLOCKIFY_OPEN=desktop" "$script_path" "$settings_path")"
  calendar_click="$(build_reexec_cmd "CLOCKIFY_OPEN=calendar" "$script_path" "$settings_path")"
  reports_click="$(build_reexec_cmd "CLOCKIFY_OPEN=reports" "$script_path" "$settings_path")"

  local rows_json
  rows_json="$(jq -n \
    --arg icon "$CLOCKIFY_ICON" \
    --arg current_label "$current_label" \
    --arg current_click "$current_click" \
    --arg desktop_click "$desktop_click" \
    --arg calendar_click "$calendar_click" \
    --arg reports_click "$reports_click" \
    '[
      {icon: $icon, text: $current_label, click: $current_click},
      {icon: "󰍹", text: "Open Clockify Desktop", click: $desktop_click},
      {icon: "󰃭", text: "Open Calendar", click: $calendar_click},
      {icon: "󰈙", text: "Open Reports", click: $reports_click}
    ]')"

  local i label click row_json
  for (( i = 0; i < ${#recent[@]} && i < max_rows; i++ )); do
    label="${recent[$i]}"
    click="$(build_reexec_cmd "CLOCKIFY_START_INDEX=${i}" "$script_path" "$settings_path")"
    row_json="$(jq -n --arg text "$label" --arg click "$click" '{icon: "󰐊", text: $text, click: $click}')"
    rows_json="$(jq --argjson row "$row_json" '. + [$row]' <<<"$rows_json")"
  done
  printf '%s' "$rows_json"
}

##############################################################################
# Runtime state/cache I/O: $XDG_STATE_HOME/ridge/clockify/ - ids (workspace +
# user id) and entries.json (the running flag, current label, and resumable
# recent-task history), same convention as mindfulness's state dir.
##############################################################################

_clockify_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/clockify"
  mkdir -p "$dir" && chmod 0700 "$dir"
  printf '%s' "$dir"
}

# Set once the missing/unreadable-token warning has been logged in this
# process, so a poll loop logs it at most once per run instead of once per
# tick - same convention as media.sh's `_media_logged_missing`.
_clockify_logged_missing_token=0
_clockify_warn_missing_token_once() {
  if [[ "$_clockify_logged_missing_token" -eq 0 ]]; then
    echo "clockify: token file '${SETTING_token_file}' is missing, unreadable, or empty - skipping network calls" >&2
    _clockify_logged_missing_token=1
  fi
}

# Reads and trims the token file. Prints nothing (never logs the value) when
# missing, unreadable, or empty after trimming - the secret only ever lives
# in this shell variable, in-process; it is never written to ridge.yaml, the
# state dir, or any log line.
_clockify_read_token() {
  local file="$SETTING_token_file" raw
  [[ -r "$file" ]] || { printf ''; return 0; }
  raw="$(cat "$file" 2>/dev/null)"
  _clockify_clean_token "$raw"
}

# Reads the cached "WS USERID" line, fetching it via `$API/user` when the
# cache is missing or empty. Prints "WS USERID" (possibly both empty on
# failure) so callers can `read -r ws userid <<<"$(...)"`.
_clockify_ensure_ids() {
  local token="$1" cache; cache="$(_clockify_state_dir)/ids"
  if [[ ! -s "$cache" ]]; then
    _clockify_fetch_ids "$token" "$cache"
  fi
  if [[ -s "$cache" ]]; then
    cat "$cache"
  fi
}

_clockify_fetch_ids() {
  local token="$1" cache="$2" tmp resp ws userid
  tmp="${cache}.tmp.$$"
  resp="$(curl -sf --max-time "$SETTING_request_timeout" -K <(printf 'header = "X-Api-Key: %s"\n' "$token") "${CLOCKIFY_API}/user" 2>/dev/null)"
  [[ -n "$resp" ]] || return 1
  ws="$(jq -r '.activeWorkspace // empty' <<<"$resp" 2>/dev/null)"
  userid="$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)"
  [[ -n "$ws" && -n "$userid" ]] || return 1
  printf '%s %s\n' "$ws" "$userid" > "$tmp" && mv -f "$tmp" "$cache"
}

# True when the cached entries.json (written by the last successful poll)
# reports a running timer.
_clockify_is_running() {
  local cache; cache="$(_clockify_state_dir)/entries.json"
  [[ -f "$cache" ]] && [[ "$(jq -r '.running // false' "$cache" 2>/dev/null)" == "true" ]]
}

_clockify_start_clear() {
  local token="$1" ws="$2" now body
  [[ -n "$ws" ]] || return 0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  body="$(jq -n --arg now "$now" '{start: $now, description: ""}')"
  curl -sf --max-time "$SETTING_request_timeout" -X POST -K <(printf 'header = "X-Api-Key: %s"\n' "$token") -H "Content-Type: application/json" \
    -d "$body" "${CLOCKIFY_API}/workspaces/${ws}/time-entries" >/dev/null 2>&1 || true
}

_clockify_stop() {
  local token="$1" ws="$2" userid="$3" now body
  [[ -n "$ws" && -n "$userid" ]] || return 0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  body="$(jq -n --arg now "$now" '{end: $now}')"
  curl -sf --max-time "$SETTING_request_timeout" -X PATCH -K <(printf 'header = "X-Api-Key: %s"\n' "$token") -H "Content-Type: application/json" \
    -d "$body" "${CLOCKIFY_API}/workspaces/${ws}/user/${userid}/time-entries" >/dev/null 2>&1 || true
}

# Sketchybar-style pill background flags for the item's `ridge add` call -
# extracted so bats can assert the flags without invoking the real `ridge`
# CLI. No bg-color here: tracking/idle/warn colors already serve as the pill
# color, applied separately by each paint call (mirrors mindfulness).
_pill_flags() {
  local out=""
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- '--bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

# One poll tick: repaint from the token/ids/time-entries chain. Also used for
# the instant-feedback repaint after a toggle/stop/start-by-index/open click.
_clockify_poll_and_paint() {
  local token; token="$(_clockify_read_token)"
  if [[ -z "$token" ]]; then
    _clockify_warn_missing_token_once
    ridge set "$ITEM_ID" --icon-color "$SETTING_warn_color" --bg-color "$SETTING_warn_color" 2>/dev/null || true
    return 0
  fi

  local ids ws userid
  ids="$(_clockify_ensure_ids "$token")"
  read -r ws userid <<<"$ids"
  if [[ -z "$ws" || -z "$userid" ]]; then
    # Ids unavailable (never fetched successfully yet) - skip this tick,
    # leaving the previous paint in place; the next tick retries.
    return 0
  fi

  local raw
  raw="$(curl -sf --max-time "$SETTING_request_timeout" -K <(printf 'header = "X-Api-Key: %s"\n' "$token") \
    "${CLOCKIFY_API}/workspaces/${ws}/user/${userid}/time-entries?page-size=25&hydrated=true" 2>/dev/null)"
  if [[ -z "$raw" ]]; then
    # Hard failure with cached ids - clear them so the next poll re-fetches
    # (covers a workspace/user id that has since changed, or a bad cache
    # entry). This is a deliberate simplification over trying to distinguish
    # curl failure causes; see README.md.
    rm -f "$(_clockify_state_dir)/ids"
    return 0
  fi

  local cache tmp out
  cache="$(_clockify_state_dir)/entries.json"
  tmp="${cache}.tmp.$$"
  # clockify_parse.py is vendored verbatim and writes directly to argv[1];
  # passing it a tmp path and mv'ing into place here keeps the cache update
  # atomic without modifying the vendored script.
  out="$(printf '%s' "$raw" | python3 "${PLUGIN_ROOT}/clockify_parse.py" "$tmp" "$SETTING_max_rows" 2>/dev/null)"
  if [[ -n "$out" && -s "$tmp" ]]; then
    mv -f "$tmp" "$cache"
  else
    rm -f "$tmp"
    return 0
  fi

  local -a lines; mapfile -t lines <<<"$out"
  local state="${lines[0]:-}" current_label="${lines[1]:-}"
  local -a recent=("${lines[@]:2}")

  local bg; bg="$(_clockify_state_color "$state" "$SETTING_tracking_color" "$SETTING_idle_color")"
  ridge set "$ITEM_ID" --icon-color "$SETTING_icon_color" --bg-color "$bg" 2>/dev/null || true

  local rows_json
  rows_json="$(_clockify_popup_rows_json "$current_label" "$SETTING_max_rows" "${recent[@]}")"
  ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
}

# Entry point for CLOCKIFY_ACTION=<toggle|stop>: toggle is the left-click
# behavior (stop if running, else start a blank/cleared entry); stop is the
# popup's "current task" row, which always stops regardless of state -
# ported verbatim from the sketchybar source's clockify_stop.sh being wired
# to that row unconditionally.
_clockify_handle_action() {
  local action="$1" token
  token="$(_clockify_read_token)"
  if [[ -z "$token" ]]; then
    _clockify_warn_missing_token_once
    return 0
  fi
  local ids ws userid
  ids="$(_clockify_ensure_ids "$token")"
  read -r ws userid <<<"$ids"

  case "$action" in
    toggle)
      if _clockify_is_running; then
        _clockify_stop "$token" "$ws" "$userid"
      else
        _clockify_start_clear "$token" "$ws"
      fi
      ;;
    stop)
      _clockify_stop "$token" "$ws" "$userid"
      ;;
  esac
  ridge popup hide "$ITEM_ID" 2>/dev/null || true
  _clockify_poll_and_paint
}

# Entry point for CLOCKIFY_START_INDEX=<i>: the index-into-cache pattern -
# resumes the cached history[i] entry (same description/project/task/tags)
# with a fresh start time, ported from the sketchybar source's
# clockify_start.sh. Looked up via jq against the SAME state-dir cache the
# poll's clockify_parse.py invocation just wrote, never a separate /tmp file.
_clockify_handle_start_index() {
  local idx="$1" token
  token="$(_clockify_read_token)"
  if [[ -z "$token" ]]; then
    _clockify_warn_missing_token_once
    return 0
  fi
  local ids ws
  ids="$(_clockify_ensure_ids "$token")"
  read -r ws _ <<<"$ids"
  [[ -n "$ws" ]] || return 0

  local cache; cache="$(_clockify_state_dir)/entries.json"
  [[ -f "$cache" ]] || return 0
  local count
  count="$(jq -r '.history | length' "$cache" 2>/dev/null)"
  [[ -n "$count" ]] || count=0
  _clockify_index_in_range "$idx" "$count" || return 0

  local entry now body
  entry="$(jq -c --argjson idx "$idx" '.history[$idx]' "$cache" 2>/dev/null)"
  [[ -n "$entry" && "$entry" != "null" ]] || return 0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  body="$(_clockify_resume_body_json "$entry" "$now")"
  [[ -n "$body" ]] || return 0

  curl -sf --max-time "$SETTING_request_timeout" -X POST -K <(printf 'header = "X-Api-Key: %s"\n' "$token") -H "Content-Type: application/json" \
    -d "$body" "${CLOCKIFY_API}/workspaces/${ws}/time-entries" >/dev/null 2>&1 || true

  ridge popup hide "$ITEM_ID" 2>/dev/null || true
  _clockify_poll_and_paint
}

# Entry point for CLOCKIFY_OPEN=<desktop|calendar|reports>: opens the
# Clockify Desktop app (or its web tracker if the app isn't installed), the
# web calendar, or the web reports page, then closes the popup. Ported
# verbatim from the sketchybar source's clockify_open.sh.
_clockify_handle_open() {
  local dest="$1"
  case "$dest" in
    desktop) open -a "Clockify Desktop" >/dev/null 2>&1 || open "https://app.clockify.me/tracker" >/dev/null 2>&1 ;;
    calendar) open "https://app.clockify.me/calendar" >/dev/null 2>&1 ;;
    reports) open "https://app.clockify.me/reports/detailed" >/dev/null 2>&1 ;;
  esac
  ridge popup hide "$ITEM_ID" 2>/dev/null || true
}

main() {
  for dep in jq curl python3 ridge; do
    if ! _have "$dep"; then echo "clockify: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  load_settings

  if [[ -n "${CLOCKIFY_ACTION:-}" ]]; then
    _clockify_handle_action "$CLOCKIFY_ACTION"
    exit 0
  fi
  if [[ -n "${CLOCKIFY_START_INDEX:-}" ]]; then
    _clockify_handle_start_index "$CLOCKIFY_START_INDEX"
    exit 0
  fi
  if [[ -n "${CLOCKIFY_OPEN:-}" ]]; then
    _clockify_handle_open "$CLOCKIFY_OPEN"
    exit 0
  fi

  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "clockify: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi

  local left_click_cmd
  left_click_cmd="$(build_reexec_cmd "CLOCKIFY_ACTION=toggle" "${PLUGIN_ROOT}/clockify.sh" "${RIDGE_PLUGIN_SETTINGS:-}")"

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (numbers only)
  ridge add "$ITEM_ID" --region "$SETTING_region" --text "" --icon "$CLOCKIFY_ICON" --icon-color "$SETTING_icon_color" --bg-color "$SETTING_idle_color" --click "$left_click_cmd" --right-click "ridge popup toggle $ITEM_ID" --font "$SETTING_font" $(_pill_flags) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    _clockify_poll_and_paint
    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so
# the guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

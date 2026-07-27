#!/usr/bin/env bash
# Ridge media plugin: now-playing controls via `nowplaying-cli` - a bar glyph
# reflecting idle/paused/playing state (optionally with a truncated
# "artist - title" label), plus a popup with title/time rows, transport
# controls (prev/play-pause/next), +/-10s seek presets, and an "open player"
# action. Ported from sketchybar's items/media.sh + plugins/media*.sh (see
# README.md). Talks to ridge over $RIDGE_SOCKET via the `ridge` CLI.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEM_ID="media.status"

_have() { command -v "$1" >/dev/null 2>&1; }

# `timeout` isn't shipped on macOS by default; alarm+exec is the standard
# shim (matches the sibling tasks/raycast_focus plugins). Wraps every
# `nowplaying-cli` call, which the sketchybar source notes can take ~2-3s
# right after wake - a hung call must never stall the poll loop or a click.
_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this script's
# own eval; the click's env assignment, script path, and settings path must
# survive both.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Builds a self-reinvoke click command: re-exec this script with the given
# env var assignment set (plus RIDGE_PLUGIN_SETTINGS forwarded via shq), so a
# row click runs the action and repaints without waiting for the next poll.
build_reexec_cmd() {
  local env_assignment="$1" script_path="$2" settings_path="${3:-}"
  local out="$env_assignment"
  if [[ -n "$settings_path" ]]; then
    out="RIDGE_PLUGIN_SETTINGS=$(shq "$settings_path") ${out}"
  fi
  printf '%s %s' "$out" "$(shq "$script_path")"
}

# shellcheck disable=SC2034 # SETTING_* consumed by main()/paint helpers, not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  # Icon font: the idle/playing/paused icons are Nerd Font glyphs, so they
  # render as tofu in the system default font unless a Nerd Font family
  # is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  # Poll interval in seconds. Must be a positive number, else default 3 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "3"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="3"
  SETTING_show_label="$(jq -r '.show_label // "true"' <<<"$json")"
  SETTING_label_max_length="$(jq -r '.label_max_length // "30"' <<<"$json")"
  [[ "$SETTING_label_max_length" =~ ^[0-9]+$ && "$SETTING_label_max_length" -ge 5 && "$SETTING_label_max_length" -le 100 ]] || SETTING_label_max_length="30"
  SETTING_idle_icon="$(jq -r '.idle_icon // "󰝚"' <<<"$json")"
  SETTING_idle_color="$(jq -r '.idle_color // "theme:secondary"' <<<"$json")"
  SETTING_playing_icon="$(jq -r '.playing_icon // "󰏤"' <<<"$json")"
  SETTING_playing_icon_color="$(jq -r '.playing_icon_color // "theme:primary"' <<<"$json")"
  SETTING_playing_bg_color="$(jq -r '.playing_bg_color // "theme:background"' <<<"$json")"
  SETTING_paused_icon="$(jq -r '.paused_icon // "󰐊"' <<<"$json")"
  SETTING_paused_icon_color="$(jq -r '.paused_icon_color // "#12161D"' <<<"$json")"
  SETTING_paused_bg_color="$(jq -r '.paused_bg_color // "theme:warning"' <<<"$json")"
  # Sketchybar-style pill geometry, matching the other widgets' pills.
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

# "--bg-height N" only when the user explicitly set bg_height; empty
# otherwise so the item's `ridge add` call omits the flag and the pill
# height auto-adapts to the bar height (TASK-139).
_bg_height_flag() {
  [[ -n "$SETTING_bg_height" ]] && printf -- '--bg-height %s' "$SETTING_bg_height"
  return 0
}

# "--bg-corner-radius N" only when the user explicitly set corner_radius;
# empty otherwise so the item's `ridge add` call omits the flag and ridge
# core's global bar.item_corner_radius default applies.
_corner_radius_flag() {
  [[ -n "$SETTING_corner_radius" ]] && printf -- '--bg-corner-radius %s' "$SETTING_corner_radius"
  return 0
}

##############################################################################
# Pure parsing/formatting functions: no I/O, no `nowplaying-cli` calls -
# callers pass explicit values so these are directly testable against
# fixtures (see tests/parse.bats, tests/format.bats, tests/glyph.bats,
# tests/seek.bats, tests/open.bats).
##############################################################################

# Extracts the Nth line from a `nowplaying-cli get ...` blob (one value per
# requested key, in request order).
_media_field() {
  local data="$1" line="$2"
  printf '%s\n' "$data" | sed -n "${line}p"
}

# idle | paused | playing. Idle when title is empty/"null"; otherwise paused
# when playbackRate is zero-equivalent/empty/"null", else playing - matches
# the sketchybar source's exact case list.
_media_classify_state() {
  local title="$1" rate="$2"
  if [[ -z "$title" || "$title" == "null" ]]; then
    printf 'idle'
    return
  fi
  case "$rate" in
    0 | 0.0 | 0.000000 | "" | null) printf 'paused' ;;
    *) printf 'playing' ;;
  esac
}

# "artist - title" when artist is present/non-null, else just "title".
_media_build_label() {
  local artist="$1" title="$2"
  if [[ -n "$artist" && "$artist" != "null" ]]; then
    printf '%s - %s' "$artist" "$title"
  else
    printf '%s' "$title"
  fi
}

# Truncates to at most $max characters, appending an ellipsis when cut.
# Assumes a UTF-8 locale (the default shell environment on macOS), same
# assumption bash's own `${#var}`/substring expansion relies on.
_media_truncate_label() {
  local label="$1" max="$2"
  if (( ${#label} <= max )); then
    printf '%s' "$label"
    return
  fi
  if (( max <= 1 )); then
    printf '%s' "${label:0:max}"
    return
  fi
  printf '%s…' "${label:0:$((max - 1))}"
}

# "M:SS"; "0:00" when the value is empty or negative (ported verbatim from
# the sketchybar source's fmt() - a zero/absent duration naturally formats
# as "0:00" too, no separate <=0 branch needed).
_media_format_time() {
  local seconds="$1"
  awk -v s="$seconds" 'BEGIN { if (s == "" || s + 0 < 0) { print "0:00"; exit } printf "%d:%02d", int(s/60), int(s%60) }'
}

# icon|icon_color|bg_color for a given state, pipe-joined. Idle shares
# playing_bg_color (the neutral bg) rather than getting its own setting,
# mirroring the sketchybar source where idle and "playing" both use the same
# background and only "paused" gets an attention color.
_media_paint_fields() {
  local state="$1"
  case "$state" in
    idle) printf '%s|%s|%s' "$SETTING_idle_icon" "$SETTING_idle_color" "$SETTING_playing_bg_color" ;;
    paused) printf '%s|%s|%s' "$SETTING_paused_icon" "$SETTING_paused_icon_color" "$SETTING_paused_bg_color" ;;
    playing) printf '%s|%s|%s' "$SETTING_playing_icon" "$SETTING_playing_icon_color" "$SETTING_playing_bg_color" ;;
  esac
}

# Clamped integer seek target (elapsed + delta, bounded to [0, duration]).
# Prints nothing and fails when duration is unavailable/<=0, so callers never
# call `nowplaying-cli seek` with a garbage target.
_media_seek_target() {
  local elapsed="$1" delta="$2" duration="$3"
  awk -v e="$elapsed" -v d="$delta" -v dur="$duration" '
    BEGIN {
      if (dur == "" || dur + 0 <= 0) { exit 1 }
      if (e == "") e = 0
      t = int(e + d)
      if (t < 0) t = 0
      if (t > dur) t = dur
      printf "%d", t
    }'
}

# Extracts ClientBundleIdentifier from `nowplaying-cli get-raw` output
# (ported verbatim sed pattern from the sketchybar source's media_open.sh).
_media_open_bundle_id() {
  local raw="$1"
  printf '%s' "$raw" | sed -n 's/.*ClientBundleIdentifier" *: *"\([^"]*\)".*/\1/p' | head -1
}

# True (status 0) when the bundle id is empty or looks like a web browser -
# in that case we open the web player instead of foregrounding the browser.
# Ported verbatim from the sketchybar source's media_open.sh case pattern.
_media_is_browser_bundle() {
  local bundle="$1"
  case "$bundle" in
    '' | company.thebrowser.* | com.google.Chrome* | com.apple.Safari* | org.mozilla.* | com.microsoft.edgemac* | com.brave.* | *[Bb]rowser*) return 0 ;;
    *) return 1 ;;
  esac
}

# Builds the 8-row popup JSON via `jq -n --arg` (not string splicing), so
# title/artist text can never break the JSON payload.
_media_popup_rows_json() {
  local title_text="$1" time_text="$2" play_icon="$3" play_text="$4"
  local script_path="${PLUGIN_ROOT}/media.sh" settings_path="${RIDGE_PLUGIN_SETTINGS:-}"
  local prev_click play_click next_click seek_back_click seek_fwd_click open_click
  prev_click="$(build_reexec_cmd "MEDIA_CTRL=prev" "$script_path" "$settings_path")"
  play_click="$(build_reexec_cmd "MEDIA_CTRL=play" "$script_path" "$settings_path")"
  next_click="$(build_reexec_cmd "MEDIA_CTRL=next" "$script_path" "$settings_path")"
  seek_back_click="$(build_reexec_cmd "MEDIA_SEEK=-10" "$script_path" "$settings_path")"
  seek_fwd_click="$(build_reexec_cmd "MEDIA_SEEK=10" "$script_path" "$settings_path")"
  open_click="$(build_reexec_cmd "MEDIA_OPEN=1" "$script_path" "$settings_path")"

  jq -n \
    --arg idle_icon "$SETTING_idle_icon" \
    --arg title_text "$title_text" \
    --arg time_text "$time_text" \
    --arg play_icon "$play_icon" \
    --arg play_text "$play_text" \
    --arg prev_click "$prev_click" \
    --arg play_click "$play_click" \
    --arg next_click "$next_click" \
    --arg seek_back_click "$seek_back_click" \
    --arg seek_fwd_click "$seek_fwd_click" \
    --arg open_click "$open_click" \
    '[
      {icon: $idle_icon, text: $title_text},
      {icon: "Time", text: $time_text},
      {icon: "󰒮", text: "Previous", click: $prev_click},
      {icon: $play_icon, text: $play_text, click: $play_click},
      {icon: "󰒭", text: "Next", click: $next_click},
      {icon: "", text: "Seek -10s", click: $seek_back_click},
      {icon: "", text: "Seek +10s", click: $seek_fwd_click},
      {icon: "󰏋", text: "Open player", click: $open_click}
    ]'
}

##############################################################################
# I/O: talks to nowplaying-cli and ridge.
##############################################################################

# Set once the missing-binary warning has been logged, so it prints at most
# once per process lifetime instead of once per poll tick. A plain variable
# is enough - the poll loop is one long-running process, not a series of
# short-lived invocations, so no on-disk flag is needed.
_media_logged_missing=0

# One poll tick: paint the bar item and (when not idle) the popup rows.
# Also used for the instant-feedback repaint after a ctrl/seek/open click,
# mirroring amphetamine's paint_state/toggle_and_paint pattern.
_media_poll_and_paint() {
  if ! _have nowplaying-cli; then
    ridge set "$ITEM_ID" --icon "$SETTING_idle_icon" --icon-color "$SETTING_idle_color" --visible off 2>/dev/null || true
    if [[ "$_media_logged_missing" -eq 0 ]]; then
      echo "media: nowplaying-cli not found in PATH - hiding item" >&2
      _media_logged_missing=1
    fi
    return
  fi

  local data title artist rate dur elapsed
  data="$(_timeout 2 nowplaying-cli get title artist playbackRate duration elapsedTime 2>/dev/null)"
  title="$(_media_field "$data" 1)"
  artist="$(_media_field "$data" 2)"
  rate="$(_media_field "$data" 3)"
  dur="$(_media_field "$data" 4)"
  elapsed="$(_media_field "$data" 5)"

  local state; state="$(_media_classify_state "$title" "$rate")"
  local fields icon icon_color bg_color
  fields="$(_media_paint_fields "$state")"
  IFS='|' read -r icon icon_color bg_color <<<"$fields"

  local title_text
  if [[ "$state" == "idle" ]]; then
    title_text="Nothing playing"
  else
    title_text="$(_media_build_label "$artist" "$title")"
  fi

  local bar_text=""
  if [[ "$SETTING_show_label" == "true" ]]; then
    bar_text="$(_media_truncate_label "$title_text" "$SETTING_label_max_length")"
  fi

  ridge set "$ITEM_ID" --icon "$icon" --icon-color "$icon_color" --bg-color "$bg_color" --text "$bar_text" --visible on 2>/dev/null || true

  local time_text play_icon play_text
  time_text="$(_media_format_time "$elapsed") / $(_media_format_time "$dur")"
  if [[ "$state" == "playing" ]]; then
    play_icon="$SETTING_playing_icon"; play_text="Pause"
  else
    play_icon="$SETTING_paused_icon"; play_text="Play"
  fi

  local rows_json
  rows_json="$(_media_popup_rows_json "$title_text" "$time_text" "$play_icon" "$play_text")"
  ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
}

# Entry point for MEDIA_CTRL=<prev|play|next>: run the transport command,
# then repaint. The 0.3s settle delay is ported from the sketchybar source's
# media_ctrl.sh, which waits for nowplaying-cli to reflect the new state
# before its own repaint.
_media_handle_ctrl() {
  local ctrl="$1"
  case "$ctrl" in
    prev) _timeout 2 nowplaying-cli previous >/dev/null 2>&1 || true ;;
    play) _timeout 2 nowplaying-cli togglePlayPause >/dev/null 2>&1 || true ;;
    next) _timeout 2 nowplaying-cli next >/dev/null 2>&1 || true ;;
  esac
  sleep 0.3
  _media_poll_and_paint
}

# Entry point for MEDIA_SEEK=<delta seconds>: reads current elapsed/duration,
# clamps the target, seeks (no-op when duration is unavailable), then repaints.
_media_handle_seek() {
  local delta="$1" data elapsed dur target
  data="$(_timeout 2 nowplaying-cli get elapsedTime duration 2>/dev/null)"
  elapsed="$(_media_field "$data" 1)"
  dur="$(_media_field "$data" 2)"
  target="$(_media_seek_target "$elapsed" "$delta" "$dur")"
  if [[ -n "$target" ]]; then
    _timeout 2 nowplaying-cli seek "$target" >/dev/null 2>&1 || true
  fi
  _media_poll_and_paint
}

# Entry point for MEDIA_OPEN=1: foreground the playing app, or open the web
# player when the source is a browser tab (ported verbatim from the
# sketchybar source's media_open.sh), then close the popup.
_media_handle_open() {
  local raw bundle
  raw="$(_timeout 2 nowplaying-cli get-raw 2>/dev/null)"
  bundle="$(_media_open_bundle_id "$raw")"
  if _media_is_browser_bundle "$bundle"; then
    open "https://music.youtube.com" >/dev/null 2>&1 || true
  else
    open -b "$bundle" >/dev/null 2>&1 || true
  fi
  ridge popup hide "$ITEM_ID" 2>/dev/null || true
}

main() {
  for dep in jq ridge; do
    if ! _have "$dep"; then echo "media: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  load_settings

  if [[ -n "${MEDIA_CTRL:-}" ]]; then
    _media_handle_ctrl "$MEDIA_CTRL"
    exit 0
  fi
  if [[ -n "${MEDIA_SEEK:-}" ]]; then
    _media_handle_seek "$MEDIA_SEEK"
    exit 0
  fi
  if [[ -n "${MEDIA_OPEN:-}" ]]; then
    _media_handle_open
    exit 0
  fi

  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "media: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi

  # shellcheck disable=SC2046 # _corner_radius_flag/_bg_height_flag each emit a single --flag value pair with no embedded whitespace, or nothing
  ridge add "$ITEM_ID" --region "$SETTING_region" --text "" --icon "$SETTING_idle_icon" --icon-color "$SETTING_idle_color" --bg-color "$SETTING_playing_bg_color" --click "ridge popup toggle $ITEM_ID" --font "$SETTING_font" --icon-padding-right 8 $(_corner_radius_flag) $(_bg_height_flag) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    _media_poll_and_paint
    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so
# the guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

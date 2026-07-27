#!/usr/bin/env bash
set -uo pipefail
# Keyboard-layout flag widget. macOS posts no event when the input source
# changes, so this polls the current layout on an interval and maps its id to a
# flag glyph. The layout is read from the live Carbon TIS API via a small
# compiled Swift helper (authoritative, reflects every switch method instantly),
# falling back to the `defaults` preference when no Swift toolchain is available
# - the preference can lag or miss some switch paths, which is why the helper is
# preferred. There's no on-disk cache of the last-painted layout to skip
# redundant sets - a plain poll-and-set each interval is simpler and the
# redundant `ridge set` is cheap.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC2034 # SETTING_* consumed by main(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  SETTING_interval="$(jq -r '.interval // "1"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="1"
  # Pill background, matching aerospace's workspace bubbles.
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

# Pill background flags for the item's `ridge add` call -
# extracted so bats can assert the flags without invoking the real `ridge`
# CLI.
_pill_flags() {
  local out
  out="$(printf -- '--bg-color %s' "$SETTING_bg_color")"
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- ' --bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

# State dir for the compiled TIS helper binary.
_kb_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/keyboard"
  mkdir -p "$dir" && chmod 0700 "$dir"
  printf '%s' "$dir"
}

# Path to the compiled keyboard_current helper, compiling it once (cached) if
# missing or older than its source. Prints the binary path on success, nothing
# if a Swift compiler is unavailable or the build fails (caller falls back to
# `defaults`). Compilation is ~1s and happens at most once per plugin version.
_kb_helper() {
  local src="${PLUGIN_ROOT}/keyboard_current.swift" bin
  bin="$(_kb_state_dir)/keyboard_current"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    command -v swiftc >/dev/null 2>&1 || return 0
    swiftc -O -o "$bin" "$src" >/dev/null 2>&1 || { rm -f "$bin"; return 0; }
  fi
  [[ -x "$bin" ]] && printf '%s' "$bin"
}

# Current keyboard layout source id. Prefers the live TIS helper; falls back to
# the `defaults` preference (helper unavailable, or a transient empty read).
read_layout() {
  local helper out
  helper="$(_kb_helper)"
  if [[ -n "$helper" ]]; then
    out="$("$helper" 2>/dev/null)"
    [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  fi
  defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null
}

# Maps a keyboard input source id to a flag glyph. Deliberately small - only
# Hungarian and US/English layouts are distinguished; anything else gets a
# neutral white flag.
layout_glyph() {
  local src="$1"
  case "$src" in
    *[Hh]ungar*)             printf '%s' '🇭🇺' ;;
    *US*|*ABC*|*[Ee]nglish*) printf '%s' '🇺🇸' ;;
    *)                       printf '%s' '🏳️' ;;
  esac
}

main() {
  for dep in jq ridge; do
    if ! command -v "$dep" >/dev/null 2>&1; then echo "keyboard: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "keyboard: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors/numbers only)
  ridge add keyboard.layout --region "$SETTING_region" --text "starting" $(_pill_flags) || true
  trap 'ridge remove keyboard.layout 2>/dev/null; exit 0' TERM INT

  local src glyph
  while true; do
    src="$(read_layout)"
    if [[ -n "$src" ]]; then
      glyph="$(layout_glyph "$src")"
      ridge set keyboard.layout --text "$glyph" 2>/dev/null || true
    fi
    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

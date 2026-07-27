#!/usr/bin/env bash
# Ridge notifications plugin: colorizes a target item's background (the
# clock item by default) while macOS Notification Center has unread
# notifications, and restores the normal colors when cleared. Owns no items
# of its own: it re-styles a foreign item via the manifest's
# `permissions.styles` grant (style-only `set`, enforced at the socket).
# Talks to ridge over $RIDGE_SOCKET via the `ridge` CLI.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_have() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC2034 # SETTING_* are consumed by main(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  # Poll interval in seconds. Must be a positive number, else default 10 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "10"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="10"
  # The foreign item to tint. Changing it also requires editing the manifest's
  # permissions.styles list - the grant is deliberately not settings-driven.
  SETTING_target_item="$(jq -r '.target_item // "clock.time"' <<<"$json")"
  [[ -n "$SETTING_target_item" ]] || SETTING_target_item="clock.time"
  # Colors must be #RRGGBB/#RRGGBBAA or a theme:<name> token (TASK-106): the
  # values are word-split into the `ridge set` argv (see _style_flags), so a
  # value with embedded whitespace would inject extra flags. Invalid values
  # fall back to the defaults.
  SETTING_tint_bg_color="$(jq -r '.tint_bg_color // "theme:warning"' <<<"$json")"
  _valid_color "$SETTING_tint_bg_color" || SETTING_tint_bg_color="theme:warning"
  SETTING_tint_label_color="$(jq -r '.tint_label_color // "#12161D"' <<<"$json")"
  _valid_color "$SETTING_tint_label_color" || SETTING_tint_label_color="#12161D"
  SETTING_normal_bg_color="$(jq -r '.normal_bg_color // "theme:background"' <<<"$json")"
  _valid_color "$SETTING_normal_bg_color" || SETTING_normal_bg_color="theme:background"
  SETTING_normal_label_color="$(jq -r '.normal_label_color // "theme:primary"' <<<"$json")"
  _valid_color "$SETTING_normal_label_color" || SETTING_normal_label_color="theme:primary"
}

# Theme-name charset here is intentionally narrower than the config surface (custom theme names with spaces/colons are rejected) because the value is expanded unquoted into ridge set flags - do not loosen.
_valid_color() { [[ "$1" =~ ^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$ || "$1" =~ ^theme:[A-Za-z0-9_-]+$ ]]; }

# Core Data epoch cutoff for a 3-day recency window, given the current epoch
# time in seconds. Pure function of "now" - no `date` call inside, so it's
# unit-testable without mocking the clock. Passed to notifications_unseen.py
# as the recency safety net (see that file's docstring for why).
_notif_cut() { echo $(( $1 - 259200 - 978307200 )); }

# Parses the python helper's combined stdout+stderr into a plain integer
# count, or empty string on any non-numeric/error output (missing Full Disk
# Access, schema drift, or any other failure the helper degrades on).
_notif_parse_count() {
  local raw="${1//[[:space:]]/}"
  case "$raw" in
    '' | *[!0-9]*) printf '' ;;
    *) printf '%s' "$raw" ;;
  esac
}

# Counts notifications currently in the Notification Center list (the
# usernoted `displayed` blob, per app - see notifications_unseen.py for the
# blob format and the recency-window safety net that keeps a desynced row
# from pinning the tint forever). `displayed` is what's on screen now;
# `delivered` accumulates dismissed/auto-delivered entries and would tint
# for notifications the user cannot see. This also covers the Focus/DND
# case: a suppressed notification still sits in NC, so it is in `displayed`.
# (`record.presented` is 0 for every row on macOS 26.5.2, so it is unusable.)
_notif_query() {
  local cut
  cut="$(_notif_cut "$(date +%s)")"
  RIDGE_NOTIF_CUTOFF="$cut" python3 "${PLUGIN_ROOT}/notifications_unseen.py" 2>&1
}

# Desired tint state for a parsed count: "tint" while notifications are
# pending, "normal" when cleared - and "normal" on a query error too (empty
# count), so a permissions problem never leaves the clock stuck tinted.
_notif_state() {
  local count="$1"
  if [[ -n "$count" && "$count" -gt 0 ]]; then printf 'tint'; else printf 'normal'; fi
}

# Style-only `ridge set` flags per state - extracted so bats can assert the
# flags without invoking the real `ridge` CLI. These are the ONLY fields the
# manifest's styles grant permits on the foreign target item.
_style_flags() {
  case "$1" in
    tint)   printf -- '--bg-color %s --color %s' "$SETTING_tint_bg_color" "$SETTING_tint_label_color" ;;
    normal) printf -- '--bg-color %s --color %s' "$SETTING_normal_bg_color" "$SETTING_normal_label_color" ;;
  esac
}

main() {
  for dep in jq python3 ridge; do
    if ! _have "$dep"; then echo "notifications: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "notifications: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # Leave the clock in its normal colors when the plugin stops.
  # shellcheck disable=SC2046 # _style_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors only)
  trap 'ridge set "$SETTING_target_item" $(_style_flags normal) 2>/dev/null; exit 0' TERM INT

  local _notif_logged_error=0 last_state=""
  while true; do
    local raw count state
    raw="$(_notif_query)"
    count="$(_notif_parse_count "$raw")"
    state="$(_notif_state "$count")"
    if [[ -z "$count" && "$_notif_logged_error" -eq 0 ]]; then
      echo "notifications: failed to query notification database (Full Disk Access not granted, or schema changed) - keeping normal colors" >&2
      _notif_logged_error=1
    fi
    # Only touch the wire on a state change: the target belongs to another
    # plugin, so redundant sets are pure noise on its item.
    if [[ "$state" != "$last_state" ]]; then
      # shellcheck disable=SC2046 # see trap note above
      if ridge set "$SETTING_target_item" $(_style_flags "$state") 2>/dev/null; then
        last_state="$state"
      fi
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

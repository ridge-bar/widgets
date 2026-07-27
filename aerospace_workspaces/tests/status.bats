#!/usr/bin/env bats
# aerospace_ws.status "AeroSpace down" warning item: settings default/override,
# the add-or-set/hide helpers, and the shown/hidden flag gating that keeps
# subscribe_loop's reconnect branch and run_reconcile's success path from
# calling ridge redundantly.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
  load_settings
  CALL_LOG="$(mktemp)"
}
teardown() { rm -f "$CALL_LOG"; }

# Stub ridge: log each invocation as one bracketed-arg line instead of
# hitting a real socket. Defined per-test so a test can vary its behavior
# (e.g. make `ridge add` fail to exercise the set-fallback path).
_log_ridge_call() { { printf 'ridge'; printf ' [%s]' "$@"; printf '\n'; } >>"$CALL_LOG"; }

@test "load_settings has status_color default theme:error" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_status_color" = "theme:error" ]
}

@test "load_settings overrides status_color from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"status_color":"#FF0000"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_status_color" = "#FF0000" ]
  rm -f "$f"
}

@test "_show_aerospace_down_status adds the item with region/text/color" {
  ridge() { _log_ridge_call "$@"; return 0; }
  _show_aerospace_down_status
  run cat "$CALL_LOG"
  [ "$output" = "ridge [add] [aerospace_ws.status] [--region] [right] [--text] [AeroSpace down] [--color] [theme:error]" ]
}

@test "_show_aerospace_down_status falls back to ridge set when add fails (item already exists)" {
  ridge() {
    _log_ridge_call "$@"
    [ "$1" = "add" ] && return 1
    return 0
  }
  _show_aerospace_down_status
  run tail -n1 "$CALL_LOG"
  [ "$output" = "ridge [set] [aerospace_ws.status] [--text] [AeroSpace down] [--color] [theme:error] [--visible] [on]" ]
}

@test "_hide_aerospace_down_status sets the item invisible" {
  ridge() { _log_ridge_call "$@"; return 0; }
  _hide_aerospace_down_status
  run cat "$CALL_LOG"
  [ "$output" = "ridge [set] [aerospace_ws.status] [--visible] [off]" ]
}

@test "_mark_aerospace_down shows once and sets the flag" {
  ridge() { _log_ridge_call "$@"; return 0; }
  AEROSPACE_DOWN_SHOWN=0
  _mark_aerospace_down
  [ "$AEROSPACE_DOWN_SHOWN" = "1" ]
  [ "$(wc -l <"$CALL_LOG" | tr -d ' ')" = "1" ]
}

@test "_mark_aerospace_down is a no-op (no ridge call) when already shown" {
  ridge() { _log_ridge_call "$@"; return 0; }
  AEROSPACE_DOWN_SHOWN=1
  _mark_aerospace_down
  [ "$AEROSPACE_DOWN_SHOWN" = "1" ]
  [ ! -s "$CALL_LOG" ]
}

@test "_clear_aerospace_down hides once and resets the flag" {
  ridge() { _log_ridge_call "$@"; return 0; }
  AEROSPACE_DOWN_SHOWN=1
  _clear_aerospace_down
  [ "$AEROSPACE_DOWN_SHOWN" = "0" ]
  [ "$(wc -l <"$CALL_LOG" | tr -d ' ')" = "1" ]
}

@test "_clear_aerospace_down is a no-op (no ridge call) when already hidden" {
  ridge() { _log_ridge_call "$@"; return 0; }
  AEROSPACE_DOWN_SHOWN=0
  _clear_aerospace_down
  [ "$AEROSPACE_DOWN_SHOWN" = "0" ]
  [ ! -s "$CALL_LOG" ]
}

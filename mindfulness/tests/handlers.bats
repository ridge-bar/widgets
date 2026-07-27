#!/usr/bin/env bats
# Exercises the settings-popup click handlers (MINDFULNESS_SET_* entry
# points). The ridge/afplay calls inside are unreachable without a running
# bar, but every call site already swallows failures (2>/dev/null || true),
# so these run safely against on-disk state alone.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/mindfulness.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  STATE_TMP="$(mktemp -d)"
  export XDG_STATE_HOME="$STATE_TMP"
  BIN_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$STATE_TMP" "$BIN_TMP"
}

@test "_mindfulness_handle_set_enabled(1) enables and resets cycle_start" {
  _state_write enabled 0
  _state_write cycle_start 1000
  run _mindfulness_handle_set_enabled 1
  [ "$status" -eq 0 ]
  run _state_read_enabled
  [ "$output" = "1" ]
  run _state_read cycle_start ""
  [ "$output" != "1000" ]
  [ "$output" -gt 0 ]
}

@test "_mindfulness_handle_set_enabled(0) disables without touching cycle_start" {
  _state_write enabled 1
  _state_write cycle_start 1000
  run _mindfulness_handle_set_enabled 0
  [ "$status" -eq 0 ]
  run _state_read_enabled
  [ "$output" = "0" ]
  run _state_read cycle_start ""
  [ "$output" = "1000" ]
}

@test "_mindfulness_handle_set_enabled rejects a garbage value" {
  _state_write enabled 1
  _state_write cycle_start 1000
  run _mindfulness_handle_set_enabled garbage
  [ "$status" -eq 0 ]
  run _state_read_enabled
  [ "$output" = "1" ]
  run _state_read cycle_start ""
  [ "$output" = "1000" ]
}

# --- overdue reminder flow (_mindfulness_handle_click) ---------------------
#
# interval_min=1 with cycle_start far in the past guarantees the "overdue"
# phase regardless of when the test runs, without stubbing `date`.

@test "_mindfulness_handle_click(left) while overdue shows the reminder without restarting the timer when core cannot be asked (ridge unavailable)" {
  _state_write enabled 1
  _state_write cycle_start 1000
  _state_write interval_min 1

  # Emulate `ridge` being absent rather than relying on it not being
  # installed: exit 127 with no output is exactly what the caller sees when
  # the command is not found, and it keeps the result the same on a machine
  # that does have ridge on PATH.
  cat > "${BIN_TMP}/ridge" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "${BIN_TMP}/ridge"
  PATH="${BIN_TMP}:${PATH}"

  run _mindfulness_handle_click left
  [ "$status" -eq 0 ]
  run _state_read cycle_start ""
  [ "$output" = "1000" ]

  # A second left click (e.g. the popup was dismissed by an outside click,
  # or `ridge query popup` still can't be asked) shows again - it degrades
  # to always showing rather than ever silently acknowledging.
  run _mindfulness_handle_click left
  [ "$status" -eq 0 ]
  run _state_read cycle_start ""
  [ "$output" = "1000" ]
}

# --- overdue left click routing via _popup_visible (TASK-148) --------------

@test "_mindfulness_handle_click(left) while overdue acknowledges when core reports the popup open" {
  _state_write enabled 1
  _state_write cycle_start 1000
  _state_write interval_min 1

  local calls_file="${BIN_TMP}/ridge_calls"
  cat > "${BIN_TMP}/ridge" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${calls_file}"
if [[ "\$1 \$2" == "query popup" ]]; then echo "open"; fi
EOF
  chmod +x "${BIN_TMP}/ridge"
  PATH="${BIN_TMP}:${PATH}"

  run _mindfulness_handle_click left
  [ "$status" -eq 0 ]
  run _state_read cycle_start ""
  [ "$output" != "1000" ]   # ack restarted the countdown
  [ "$output" -gt 0 ]

  run grep -- "popup hide" "${calls_file}"
  [ "$status" -eq 0 ]
}

@test "_mindfulness_handle_click(left) while overdue shows a fresh quote when core reports the popup closed" {
  _state_write enabled 1
  _state_write cycle_start 1000
  _state_write interval_min 1

  local calls_file="${BIN_TMP}/ridge_calls"
  cat > "${BIN_TMP}/ridge" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${calls_file}"
if [[ "\$1 \$2" == "query popup" ]]; then echo "closed"; fi
EOF
  chmod +x "${BIN_TMP}/ridge"
  PATH="${BIN_TMP}:${PATH}"

  run _mindfulness_handle_click left
  [ "$status" -eq 0 ]
  run _state_read cycle_start ""
  [ "$output" = "1000" ]   # not acknowledged - countdown untouched

  run grep -- "popup set-rows" "${calls_file}"
  [ "$status" -eq 0 ]
  run grep -- "popup show" "${calls_file}"
  [ "$status" -eq 0 ]
}

@test "_mindfulness_handle_click(left) while overdue shows when the ridge query fails or returns garbage" {
  _state_write enabled 1
  _state_write cycle_start 1000
  _state_write interval_min 1

  local calls_file="${BIN_TMP}/ridge_calls"
  cat > "${BIN_TMP}/ridge" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${calls_file}"
if [[ "\$1 \$2" == "query popup" ]]; then echo "not-json-garbage"; exit 1; fi
EOF
  chmod +x "${BIN_TMP}/ridge"
  PATH="${BIN_TMP}:${PATH}"

  run _mindfulness_handle_click left
  [ "$status" -eq 0 ]
  run _state_read cycle_start ""
  [ "$output" = "1000" ]   # degrades to show, never a silent ack

  run grep -- "popup show" "${calls_file}"
  [ "$status" -eq 0 ]
}

@test "_mindfulness_handle_click(ack) hides the popup and restarts the countdown" {
  _state_write enabled 1
  _state_write cycle_start 1000
  _state_write interval_min 1

  run _mindfulness_handle_click ack
  [ "$status" -eq 0 ]
  run _state_read cycle_start ""
  [ "$output" != "1000" ]
  [ "$output" -gt 0 ]
}

@test "_mindfulness_handle_click(ack) while disabled keeps the disabled paint and skips the countdown restart" {
  _state_write enabled 0
  _state_write cycle_start 1000
  _state_write interval_min 1

  local calls_file="${BIN_TMP}/ridge_calls"
  cat > "${BIN_TMP}/ridge" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${calls_file}"
EOF
  chmod +x "${BIN_TMP}/ridge"
  PATH="${BIN_TMP}:${PATH}"

  run _mindfulness_handle_click ack
  [ "$status" -eq 0 ]
  run _state_read cycle_start ""
  [ "$output" = "1000" ]

  run grep -- "--bg-color $SETTING_disabled_color" "${calls_file}"
  [ "$status" -eq 0 ]
}

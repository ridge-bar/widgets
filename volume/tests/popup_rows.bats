#!/usr/bin/env bats
# Exercises _volume_popup_rows_json's output/input slider rows: the fixed
# 25/50/75/100% preset rows were replaced by one draggable slider per
# section. Confirms the slider's row shape and, critically, that its submit
# command still carries the literal (unexpanded) $RIDGE_SLIDER token - ridge
# core expands it via /bin/sh -c only at slider-change time, never here.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/volume.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  BIN_DIR="$(mktemp -d)"
  cat > "${BIN_DIR}/osascript" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"input volume of"*) printf '%s\n' "${MOCK_INPUT_VOLUME:-37}" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${BIN_DIR}/osascript"
  cat > "${BIN_DIR}/SwitchAudioSource" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-a -t output") printf 'Speakers\n' ;;
  "-c -t output") printf 'Speakers\n' ;;
  "-a -t input") printf 'Microphone\n' ;;
  "-c -t input") printf 'Microphone\n' ;;
esac
EOF
  chmod +x "${BIN_DIR}/SwitchAudioSource"
  PATH="${BIN_DIR}:${PATH}"
  RIDGE_PLUGIN_SETTINGS=""
  export MOCK_INPUT_VOLUME=37
  # Isolate _state_read/_state_write (input_muted, etc.) from the real
  # machine's ridge state so this test never depends on the host's actual
  # volume plugin history.
  export XDG_STATE_HOME="${BIN_DIR}/state"
}

teardown() {
  rm -rf "$BIN_DIR"
}

@test "_volume_popup_rows_json emits valid JSON" {
  run _volume_popup_rows_json "0" "60"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "_volume_popup_rows_json output slider: type/min/max/value and a \$RIDGE_SLIDER submit targeting VOLUME_SET" {
  run _volume_popup_rows_json "0" "60"
  [ "$status" -eq 0 ]
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  local slider; slider="$(jq -c '[.[] | select(.type == "slider")][0]' "$f")"
  rm -f "$f"
  [ "$(jq -rn --argjson s "$slider" '$s.min')" = "0" ]
  [ "$(jq -rn --argjson s "$slider" '$s.max')" = "100" ]
  [ "$(jq -rn --argjson s "$slider" '$s.value')" = "60" ]
  [[ "$(jq -rn --argjson s "$slider" '$s.value')" =~ ^[0-9]+$ ]]
  local submit; submit="$(jq -rn --argjson s "$slider" '$s.submit')"
  [[ "$submit" == *'$RIDGE_SLIDER'* ]]
  [[ "$submit" == *"VOLUME_SET="* ]]
  [[ "$submit" != *"VOLUME_SET_INPUT="* ]]
}

@test "_volume_popup_rows_json input slider: type/min/max/value and a \$RIDGE_SLIDER submit targeting VOLUME_SET_INPUT" {
  run _volume_popup_rows_json "0" "60"
  [ "$status" -eq 0 ]
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  local slider; slider="$(jq -c '[.[] | select(.type == "slider")][1]' "$f")"
  rm -f "$f"
  [ "$(jq -rn --argjson s "$slider" '$s.min')" = "0" ]
  [ "$(jq -rn --argjson s "$slider" '$s.max')" = "100" ]
  [ "$(jq -rn --argjson s "$slider" '$s.value')" = "37" ]
  [[ "$(jq -rn --argjson s "$slider" '$s.value')" =~ ^[0-9]+$ ]]
  local submit; submit="$(jq -rn --argjson s "$slider" '$s.submit')"
  [[ "$submit" == *'$RIDGE_SLIDER'* ]]
  [[ "$submit" == *"VOLUME_SET_INPUT="* ]]
}

@test "_volume_popup_rows_json drops the 25/50/75/100 percent preset rows" {
  run _volume_popup_rows_json "0" "60"
  [ "$status" -eq 0 ]
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  for pct in '25%' '50%' '75%' '100%'; do
    [ "$(jq --arg t "$pct" '[.[] | select(.text == $t)] | length' "$f")" = "0" ]
  done
  rm -f "$f"
}

@test "_volume_popup_rows_json keeps section headers, mute rows, and device rows" {
  run _volume_popup_rows_json "0" "60"
  [ "$status" -eq 0 ]
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  [ "$(jq '[.[] | select(.type == "header" and .text == "Output")] | length' "$f")" = "1" ]
  [ "$(jq '[.[] | select(.type == "header" and .text == "Input")] | length' "$f")" = "1" ]
  [ "$(jq '[.[] | select(.text == "Mute")] | length' "$f")" = "2" ]
  [ "$(jq '[.[] | select(.text == "Speakers")] | length' "$f")" = "1" ]
  [ "$(jq '[.[] | select(.text == "Microphone")] | length' "$f")" = "1" ]
  rm -f "$f"
}

@test "_volume_popup_rows_json no longer emits the +/-5% step rows" {
  run _volume_popup_rows_json "0" "60"
  [ "$status" -eq 0 ]
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  [ "$(jq '[.[] | select(.text == "Vol -5%")] | length' "$f")" = "0" ]
  [ "$(jq '[.[] | select(.text == "Vol +5%")] | length' "$f")" = "0" ]
  rm -f "$f"
}

@test "_volume_popup_rows_json non-numeric out_pct heals to 0 via _volume_clamp_pct" {
  run _volume_popup_rows_json "0" "not-a-number"
  [ "$status" -eq 0 ]
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  local slider; slider="$(jq -c '[.[] | select(.type == "slider")][0]' "$f")"
  rm -f "$f"
  [ "$(jq -rn --argjson s "$slider" '$s.value')" = "0" ]
}

#!/usr/bin/env bats
# Exercises _volume_device_rows_json, including the hostile-device-name
# safety property: a device name with shell metacharacters must never break
# the JSON output and must never become executable in the resulting click
# string (device names go through jq --arg for text, shq for the click env
# var - never string interpolation).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/volume.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  BIN_DIR="$(mktemp -d)"
  DEVICE_LIST="${BIN_DIR}/devices.txt"
  CURRENT_DEVICE_FILE="${BIN_DIR}/current.txt"
  : > "$DEVICE_LIST"
  : > "$CURRENT_DEVICE_FILE"
  export DEVICE_LIST CURRENT_DEVICE_FILE
  cat > "${BIN_DIR}/SwitchAudioSource" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-a -t "*) cat "${DEVICE_LIST}" ;;
  "-c -t "*) cat "${CURRENT_DEVICE_FILE}" ;;
esac
EOF
  chmod +x "${BIN_DIR}/SwitchAudioSource"
  PATH="${BIN_DIR}:${PATH}"
  RIDGE_PLUGIN_SETTINGS=""
}

teardown() {
  rm -rf "$BIN_DIR"
}

@test "_volume_device_rows_json returns an empty array when SwitchAudioSource is absent" {
  PATH="/usr/bin:/bin"
  run _volume_device_rows_json output
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_volume_device_rows_json emits one row per device, capped at 6" {
  for i in $(seq 1 10); do printf 'Device %s\n' "$i" >> "$DEVICE_LIST"; done
  printf 'Device 1\n' > "$CURRENT_DEVICE_FILE"
  run _volume_device_rows_json output
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 6'
}

@test "_volume_device_rows_json highlights the current device with device_active_color" {
  printf 'Speakers\nHeadphones\n' > "$DEVICE_LIST"
  printf 'Headphones\n' > "$CURRENT_DEVICE_FILE"
  run _volume_device_rows_json output
  [ "$status" -eq 0 ]
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  [ "$(jq -r '.[0] | has("color")' "$f")" = "false" ]
  [ "$(jq -r '.[1].color' "$f")" = "$SETTING_device_active_color" ]
  [ "$(jq -r '.[1].text' "$f")" = "Headphones" ]
  rm -f "$f"
}

@test "_volume_device_rows_json embeds the device type in the click command" {
  printf 'Speakers\n' > "$DEVICE_LIST"
  run _volume_device_rows_json input
  [ "$status" -eq 0 ]
  local click; click="$(echo "$output" | jq -r '.[0].click')"
  [[ "$click" == *"VOLUME_SWITCH_DEVICE_TYPE=input"* ]]
}

@test "a hostile device name never breaks JSON parsing and is shq-quoted, never raw-interpolated" {
  local hostile="\`touch pwned\` \$(touch pwned) '; touch pwned ;'"
  printf '%s\n' "$hostile" > "$DEVICE_LIST"
  run _volume_device_rows_json output
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  local f; f="$(mktemp)"
  printf '%s' "$output" > "$f"
  click="$(jq -r '.[0].click' "$f")"
  text="$(jq -r '.[0].text' "$f")"
  rm -f "$f"
  # The row's display text carries the hostile name verbatim (jq --arg made
  # it safe as a JSON string)...
  [ "$text" = "$hostile" ]
  # ...but the click's env var assignment carries it only through shq's
  # single-quote escaping - never spliced in raw. Ridge core executes the
  # click via `/bin/sh -c`, so an unescaped backtick/$()/quote here would be
  # a command-injection vector; asserting the exact shq-quoted form (rather
  # than merely "no backtick present", which single-quoting cannot promise
  # since the quoted literal still contains the original bytes) is the real
  # safety property.
  local expected_quoted; expected_quoted="$(shq "$hostile")"
  [[ "$click" == *"VOLUME_SWITCH_DEVICE_NAME=${expected_quoted}"* ]]
}

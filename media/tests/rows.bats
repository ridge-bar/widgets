#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/media.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
}

@test "_media_popup_rows_json emits 8 rows in the documented order" {
  run _media_popup_rows_json "Daft Punk - Random Access Memories" "2:08 / 6:14" "$SETTING_playing_icon" "Pause"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 8'
  echo "$output" | jq -e '.[0].text == "Daft Punk - Random Access Memories"'
  echo "$output" | jq -e '.[1].icon == "Time" and .[1].text == "2:08 / 6:14"'
  echo "$output" | jq -e '.[2].text == "Previous"'
  echo "$output" | jq -e '.[3].text == "Pause"'
  echo "$output" | jq -e '.[4].text == "Next"'
  echo "$output" | jq -e '.[5].text == "Seek -10s"'
  echo "$output" | jq -e '.[6].text == "Seek +10s"'
  echo "$output" | jq -e '.[7].text == "Open player"'
}

@test "_media_popup_rows_json wires a click on every actionable row" {
  run _media_popup_rows_json "Title" "0:00 / 0:00" "$SETTING_paused_icon" "Play"
  for i in 2 3 4 5 6 7; do
    echo "$output" | jq -e ".[$i] | has(\"click\") and (.click | length > 0)"
  done
  # Title and time rows are informational, not clickable.
  echo "$output" | jq -e '.[0] | has("click") | not'
  echo "$output" | jq -e '.[1] | has("click") | not'
}

@test "_media_popup_rows_json safely escapes JSON-breaking characters in the title" {
  run _media_popup_rows_json 'Artist" ; rm -rf / - "Evil Title' "0:00 / 0:00" "$SETTING_playing_icon" "Pause"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 8'
  echo "$output" | jq -e '.[0].text | contains("rm -rf")'
}

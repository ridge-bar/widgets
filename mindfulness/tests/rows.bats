#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/mindfulness.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
}

@test "_mindfulness_settings_rows_json emits 7 rows" {
  run _mindfulness_settings_rows_json "7m 12s left" 1 15 100
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 7'
}

@test "_mindfulness_settings_rows_json's first row carries the remaining text and no click" {
  run _mindfulness_settings_rows_json "7m 12s left" 1 15 100
  echo "$output" | jq -e '.[0].text == "7m 12s left"'
  echo "$output" | jq -e '.[0] | has("click") | not'
}

@test "_mindfulness_settings_rows_json's On/Off rows follow the remaining-time row" {
  run _mindfulness_settings_rows_json "Disabled" 0 15 100
  echo "$output" | jq -e '.[1].text == "On"'
  echo "$output" | jq -e '.[2].text == "Off"'
}

@test "_mindfulness_settings_rows_json marks the On row when enabled" {
  run _mindfulness_settings_rows_json "7m 12s left" 1 15 100
  echo "$output" | jq -e '.[1].color == "theme:success"'
  echo "$output" | jq -e '.[2] | has("color") | not'
}

@test "_mindfulness_settings_rows_json marks the Off row when disabled" {
  run _mindfulness_settings_rows_json "Disabled" 0 15 100
  echo "$output" | jq -e '.[2].color == "theme:success"'
  echo "$output" | jq -e '.[1] | has("color") | not'
}

@test "_mindfulness_settings_rows_json's preset (On/Off) rows carry a non-empty click and close_on_click=false" {
  run _mindfulness_settings_rows_json "Disabled" 1 15 100
  echo "$output" | jq -e '[.[1:3][] | (.click | length > 0) and (.close_on_click == false)] | all'
}

@test "_mindfulness_settings_rows_json's preset clicks encode the target env var" {
  run _mindfulness_settings_rows_json "Disabled" 1 15 100
  echo "$output" | jq -e '.[1].click | contains("MINDFULNESS_SET_ENABLED=1")'
  echo "$output" | jq -e '.[2].click | contains("MINDFULNESS_SET_ENABLED=0")'
}

@test "_mindfulness_settings_rows_json has an Interval label row before the interval slider" {
  run _mindfulness_settings_rows_json "Disabled" 1 15 100
  echo "$output" | jq -e '.[3].text == "Interval"'
  echo "$output" | jq -e '.[3] | has("type") | not'
}

@test "_mindfulness_settings_rows_json's interval slider row is a slider from 1 to 60" {
  run _mindfulness_settings_rows_json "Disabled" 1 30 100
  echo "$output" | jq -e '.[4].type == "slider"'
  echo "$output" | jq -e '.[4].min == 1'
  echo "$output" | jq -e '.[4].max == 60'
  echo "$output" | jq -e '.[4].step == 1'
  echo "$output" | jq -e '.[4].value == 30'
}

@test "_mindfulness_settings_rows_json's interval slider submits to MINDFULNESS_SET_INTERVAL via \$RIDGE_SLIDER" {
  run _mindfulness_settings_rows_json "Disabled" 1 30 100
  echo "$output" | jq -e '.[4].submit | contains("MINDFULNESS_SET_INTERVAL=$RIDGE_SLIDER")'
}

@test "_mindfulness_settings_rows_json has a Volume label row before the volume slider" {
  run _mindfulness_settings_rows_json "Disabled" 1 15 100
  echo "$output" | jq -e '.[5].text == "Volume"'
  echo "$output" | jq -e '.[5] | has("type") | not'
}

@test "_mindfulness_settings_rows_json's volume slider row is a slider from 0 to 100" {
  run _mindfulness_settings_rows_json "Disabled" 1 15 75
  echo "$output" | jq -e '.[6].type == "slider"'
  echo "$output" | jq -e '.[6].min == 0'
  echo "$output" | jq -e '.[6].max == 100'
  echo "$output" | jq -e '.[6].step == 1'
  echo "$output" | jq -e '.[6].value == 75'
}

@test "_mindfulness_settings_rows_json's volume slider submits to MINDFULNESS_SET_VOLUME via \$RIDGE_SLIDER" {
  run _mindfulness_settings_rows_json "Disabled" 1 15 75
  echo "$output" | jq -e '.[6].submit | contains("MINDFULNESS_SET_VOLUME=$RIDGE_SLIDER")'
}

@test "_mindfulness_settings_rows_json no longer emits the old interval/volume preset rows" {
  run _mindfulness_settings_rows_json "Disabled" 1 15 100
  echo "$output" | jq -e '[.[].text] | any(. == "5 min") | not'
  echo "$output" | jq -e '[.[].text] | any(. == "60 min") | not'
  echo "$output" | jq -e '[.[].text] | any(. == "Mute") | not'
  echo "$output" | jq -e '[.[].text] | any(. == "25%") | not'
  echo "$output" | jq -e '[.[].text] | any(. == "100%") | not'
}

@test "_mindfulness_settings_rows_json's rows never carry the Nerd Font icon glyph" {
  run _mindfulness_settings_rows_json "Disabled" 1 15 100
  echo "$output" | jq --arg icon "$MINDFULNESS_ICON" -e '[.[] | select(has("icon")) | .icon] | all(. != $icon)'
}

@test "_mindfulness_reminder_row_json emits a single row with the message" {
  run _mindfulness_reminder_row_json "Take a sip of water."
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].text == "Take a sip of water."'
}

@test "_mindfulness_reminder_row_json safely escapes JSON-breaking characters" {
  run _mindfulness_reminder_row_json 'hostile" ; rm -rf / "text'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].text | contains("rm -rf")'
}

@test "_mindfulness_reminder_row_json's icon is the font-safe leaf emoji, not the Nerd Font glyph" {
  run _mindfulness_reminder_row_json "Take a sip of water."
  local icon; icon="$(echo "$output" | jq -r '.[0].icon')"
  [ "$icon" = "$MINDFULNESS_POPUP_ICON" ]
  [ "$icon" != "$MINDFULNESS_ICON" ]
}

@test "_mindfulness_reminder_row_json's row carries a click command that acknowledges" {
  run _mindfulness_reminder_row_json "Take a sip of water."
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].click | contains("MINDFULNESS_CLICK=ack")'
}

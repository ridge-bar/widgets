#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/battery.sh"
}

@test "_battery_popup_rows_json emits 7 rows with the expected icons" {
  run _battery_popup_rows_json 85 charging 1:23 "AC Power" 96% 342 31.2C
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 7'
  echo "$output" | jq -e '[.[].icon] == ["Battery","Charge","Time left","Power","Health","Cycles","Temp"]'
}

@test "_battery_popup_rows_json fills each row's text from its argument" {
  run _battery_popup_rows_json 85 charging 1:23 "AC Power" 96% 342 31.2C
  echo "$output" | jq -e '.[1].text == "85% (charging)"'
  echo "$output" | jq -e '.[2].text == "1:23"'
  echo "$output" | jq -e '.[3].text == "AC Power"'
  echo "$output" | jq -e '.[4].text == "96%"'
  echo "$output" | jq -e '.[5].text == "342"'
  echo "$output" | jq -e '.[6].text == "31.2C"'
}

@test "_battery_popup_rows_json colors only the title row with the accent" {
  run _battery_popup_rows_json 50 discharging - Battery - - -
  echo "$output" | jq -e '.[0].color == "#9ECE6A" and .[0].icon_color == "#9ECE6A"'
  echo "$output" | jq -e '.[1] | has("color") | not'
}

@test "_battery_popup_rows_json safely escapes JSON-breaking characters in a field" {
  run _battery_popup_rows_json 12 'discharging" ; rm -rf /' 1:00 Battery - - -
  [ "$status" -eq 0 ]
  # The payload must still parse as valid JSON despite the hostile status text.
  echo "$output" | jq -e 'length == 7'
  echo "$output" | jq -e '.[1].text | contains("rm -rf")'
}

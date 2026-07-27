#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
}

@test "current_state extracts aerospace_ws.* leaf items with text and color" {
  run current_state "${FIX}/items.json" "${FIX}/brackets.json"
  [ "$status" -eq 0 ]
  # num item: empty display/monitor, text, color, empty click.
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.1\\.num\t\t\t1\t#A9B1D6\t'
  # app item likewise.
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.1\\.app\\.1\t\t\tK\t#565F89\t'
  # unrelated items excluded.
  ! echo "$output" | grep -q $'\tclock\t'
}

@test "current_state extracts only aerospace_ws.* brackets with members" {
  run current_state "${FIX}/items.json" "${FIX}/brackets.json"
  echo "$output" | grep -qE $'^BRACKET\taerospace_ws\\.1\taerospace_ws\\.1\\.num,aerospace_ws\\.1\\.app\\.1\t'
  ! echo "$output" | grep -qE $'^BRACKET\tother\t'
}

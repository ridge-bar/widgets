#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-apps-plugin.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
}

@test "current_state extracts aerospace_apps.* leaf items with text and color" {
  run current_state "${FIX}/items.json" "${FIX}/brackets.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.DELL_U2720Q\\.1\\.icon\t\t\t:ghostty:\t#565F89\t'
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.DELL_U2720Q\\.1\\.label\t\t\tGhostty\t#565F89\t'
  ! echo "$output" | grep -q $'\tclock\t'
}

@test "current_state extracts only aerospace_apps.* brackets with members" {
  run current_state "${FIX}/items.json" "${FIX}/brackets.json"
  echo "$output" | grep -qE $'^BRACKET\taerospace_apps\\.DELL_U2720Q\\.1\taerospace_apps\\.DELL_U2720Q\\.1\\.icon,aerospace_apps\\.DELL_U2720Q\\.1\\.label\t'
  ! echo "$output" | grep -qE $'^BRACKET\tother\t'
}

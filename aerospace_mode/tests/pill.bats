#!/usr/bin/env bats
# Exercises the pill flags shared by the badge's `ridge
# add`/`ridge set` calls (bg-color/corner-radius/height/padding/icon-color/
# color).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace_mode.sh"
}

@test "_pill_style_flags uses the defaults and omits corner-radius/bg-height (unset -> ridge global default / auto)" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  run _pill_style_flags
  [[ "$output" == *"--bg-color theme:warning"* ]]
  [[ "$output" != *"--bg-corner-radius"* ]]
  [[ "$output" == *"--padding-left 8"* ]]
  [[ "$output" == *"--padding-right 8"* ]]
  [[ "$output" == *"--icon-color #12161D"* ]]
  [[ "$output" == *"--color #12161D"* ]]
  [[ "$output" != *"--bg-height"* ]]
}

@test "_pill_style_flags honors an explicit corner_radius override" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"14"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  run _pill_style_flags
  [[ "$output" == *"--bg-corner-radius 14"* ]]
}

@test "_pill_style_flags honors an overridden bg_height" {
  local f; f="$(mktemp)"
  printf '%s' '{"bg_height":"30"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  run _pill_style_flags
  [[ "$output" == *"--bg-height 30"* ]]
}

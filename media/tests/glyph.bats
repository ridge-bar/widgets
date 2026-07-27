#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/media.sh"
  RIDGE_PLUGIN_SETTINGS="" load_settings
}

@test "_media_paint_fields: idle uses idle_icon/idle_color and the neutral (playing) bg" {
  run _media_paint_fields idle
  [ "$output" = "${SETTING_idle_icon}|${SETTING_idle_color}|${SETTING_playing_bg_color}" ]
}

@test "_media_paint_fields: paused uses paused_icon/paused_icon_color/paused_bg_color" {
  run _media_paint_fields paused
  [ "$output" = "${SETTING_paused_icon}|${SETTING_paused_icon_color}|${SETTING_paused_bg_color}" ]
}

@test "_media_paint_fields: playing uses playing_icon/playing_icon_color/playing_bg_color" {
  run _media_paint_fields playing
  [ "$output" = "${SETTING_playing_icon}|${SETTING_playing_icon_color}|${SETTING_playing_bg_color}" ]
}

@test "_media_paint_fields output is pipe-parseable back into three fields" {
  run _media_paint_fields playing
  local icon icon_color bg_color
  IFS='|' read -r icon icon_color bg_color <<<"$output"
  [ "$icon" = "$SETTING_playing_icon" ]
  [ "$icon_color" = "$SETTING_playing_icon_color" ]
  [ "$bg_color" = "$SETTING_playing_bg_color" ]
}

#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
}

@test "load_settings applies Tokyo Night defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_bg_color" = "theme:background" ]
  [ "$SETTING_bg_focused_color" = "theme:system" ]
  [ "$SETTING_number_color" = "theme:secondary" ]
  [ "$SETTING_glyph_color" = "theme:primary@0.5" ]
  [ "$SETTING_glyph_focused_color" = "theme:primary" ]
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_height" = "" ]
  [ "$SETTING_max_ws_apps" = "5" ]
}

@test "load_settings has sketchybar padding defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_num_pad_left" = "8" ]
  [ "$SETTING_num_pad_right" = "4" ]
  [ "$SETTING_glyph_pad_left" = "8" ]
  [ "$SETTING_glyph_pad_right" = "8" ]
}

@test "load_settings has bubble_margin default 6" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_bubble_margin" = "6" ]
}

@test "load_settings has border defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_border_focused_color" = "theme:system" ]
  [ "$SETTING_border_width" = "2" ]
}

@test "load_settings overrides from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"bg_focused_color":"#123456","max_ws_apps":"3"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_bg_focused_color" = "#123456" ]
  [ "$SETTING_max_ws_apps" = "3" ]
  [ "$SETTING_bg_color" = "theme:background" ]   # untouched key keeps default
  rm -f "$f"
}

@test "load_settings has update_mode default subscribe + poll_interval default 2" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_update_mode" = "subscribe" ]
  [ "$SETTING_poll_interval" = "2" ]
}

@test "load_settings update_mode defaults to subscribe" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_update_mode" = "subscribe" ]
}

@test "load_settings accepts subscribe, trigger, poll" {
  local m
  for m in subscribe trigger poll; do
    local f; f="$(mktemp)"
    printf '{"update_mode":"%s"}' "$m" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_update_mode" = "$m" ] || { echo "mode $m not kept: $SETTING_update_mode"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings unknown update_mode falls back to subscribe" {
  local f; f="$(mktemp)"
  printf '%s' '{"update_mode":"bogus"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_update_mode" = "subscribe" ]
  rm -f "$f"
}

@test "load_settings honors update_mode=poll and a poll_interval override" {
  local f; f="$(mktemp)"
  printf '%s' '{"update_mode":"poll","poll_interval":"1.5"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_update_mode" = "poll" ]
  [ "$SETTING_poll_interval" = "1.5" ]
  rm -f "$f"
}

@test "load_settings falls back on invalid update_mode / poll_interval" {
  local f; f="$(mktemp)"
  printf '%s' '{"update_mode":"bogus","poll_interval":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_update_mode" = "subscribe" ] # unknown mode -> subscribe
  [ "$SETTING_poll_interval" = "2" ]       # non-numeric -> default
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent poll_interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"poll_interval":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_poll_interval" = "2" ] || { echo "poll_interval=$v not rejected: got $SETTING_poll_interval"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings keeps valid fractional poll_interval like 0.5" {
  local f; f="$(mktemp)"
  printf '%s' '{"poll_interval":"0.5"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_poll_interval" = "0.5" ]
  rm -f "$f"
}

@test "load_settings has app-font defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_app_font" = "sketchybar-app-font" ]
  [ "$SETTING_app_font_style" = "Regular" ]
  [ "$SETTING_app_font_size" = "14" ]
}

@test "load_settings overrides app-font settings from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"app_font":"MyAppFont","app_font_style":"Bold","app_font_size":"16"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_app_font" = "MyAppFont" ]
  [ "$SETTING_app_font_style" = "Bold" ]
  [ "$SETTING_app_font_size" = "16" ]
  rm -f "$f"
}

@test "load_settings falls back to app-font defaults on empty/non-numeric overrides" {
  local f; f="$(mktemp)"
  printf '%s' '{"app_font":"","app_font_style":"","app_font_size":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_app_font" = "sketchybar-app-font" ]
  [ "$SETTING_app_font_style" = "Regular" ]
  [ "$SETTING_app_font_size" = "14" ]
  rm -f "$f"
}

@test "load_settings has status_color default theme:error" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_status_color" = "theme:error" ]
}

@test "load_settings has status_region default right" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_status_region" = "right" ]
}

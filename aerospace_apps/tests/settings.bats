#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-apps-plugin.sh"
}

@test "load_settings has current-window widget defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "center" ]
  [ "$SETTING_bg_color" = "theme:background" ]
  [ "$SETTING_border_focused_color" = "theme:system" ]
  [ "$SETTING_border_width" = "2" ]
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_height" = "" ]
  [ "$SETTING_pad_left" = "8" ]
  [ "$SETTING_pad_right" = "8" ]
  [ "$SETTING_bubble_margin" = "6" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_max" = "8" ]
}

@test "load_settings overrides the label font" {
  local f; f="$(mktemp)"
  printf '%s' '{"font":"JetBrains Mono"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_font" = "JetBrains Mono" ]
  rm -f "$f"
}

@test "load_settings overrides bubble_margin (gap between app bubbles)" {
  local f; f="$(mktemp)"
  printf '%s' '{"bubble_margin":"8"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_bubble_margin" = "8" ]
  rm -f "$f"
}

@test "load_settings overrides max and falls back to 8 on non-numeric" {
  local f; f="$(mktemp)"
  printf '%s' '{"max":"3"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max" = "3" ]
  printf '%s' '{"max":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max" = "8" ]
  rm -f "$f"
}

@test "load_settings overrides region and border color" {
  local f; f="$(mktemp)"
  printf '%s' '{"region":"right","border_focused_color":"#BB9AF7"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_border_focused_color" = "#BB9AF7" ]
  rm -f "$f"
}

@test "load_settings has app-font defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_app_font" = "" ]
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

@test "load_settings falls back to app-font-style/size defaults on empty/non-numeric overrides" {
  local f; f="$(mktemp)"
  printf '%s' '{"app_font":"","app_font_style":"","app_font_size":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_app_font" = "" ]
  [ "$SETTING_app_font_style" = "Regular" ]
  [ "$SETTING_app_font_size" = "14" ]
  rm -f "$f"
}

@test "load_settings has update_mode default subscribe + poll_interval default 2" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_update_mode" = "subscribe" ]
  [ "$SETTING_poll_interval" = "2" ]
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

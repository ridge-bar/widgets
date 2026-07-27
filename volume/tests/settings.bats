#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/volume.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_interval" = "5" ]
  [ "$SETTING_icon_color" = "theme:primary" ]
  [ "$SETTING_bg_color" = "theme:background" ]
  [ "$SETTING_muted_color" = "theme:error" ]
  [ "$SETTING_low_icon" = "󰕿" ]
  [ "$SETTING_mid_icon" = "󰖀" ]
  [ "$SETTING_high_icon" = "󰕾" ]
  [ "$SETTING_muted_icon" = "󰖁" ]
  [ "$SETTING_device_active_color" = "theme:success" ]
  [ "$SETTING_betterdisplay_enabled" = "false" ]
  [ "$SETTING_betterdisplay_name" = "" ]
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_bg_height" = "" ]
}

@test "load_settings falls back to empty corner_radius/bg_height on out-of-range or non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"31","bg_height":"15"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_bg_height" = "" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"corner_radius":"abc","bg_height":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_bg_height" = "" ]
  rm -f "$f"
}

@test "load_settings keeps an explicit corner_radius override" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"12"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_corner_radius" = "12" ]
  rm -f "$f"
}

@test "load_settings overrides font, falling back to the default on empty" {
  local f; f="$(mktemp)"
  printf '%s' '{"font":"MyFont"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_font" = "MyFont" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"font":""}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  rm -f "$f"
}

@test "load_settings overrides from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"icon_color":"#123456","betterdisplay_enabled":"true","betterdisplay_name":"AW3423DWF"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_icon_color" = "#123456" ]
  [ "$SETTING_betterdisplay_enabled" = "true" ]
  [ "$SETTING_betterdisplay_name" = "AW3423DWF" ]
  [ "$SETTING_bg_color" = "theme:background" ]   # untouched key keeps default
  rm -f "$f"
}

@test "load_settings falls back to default interval on non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "5" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"interval":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_interval" = "5" ] || { echo "interval=$v not rejected: got $SETTING_interval"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings keeps a valid interval override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"10"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "10" ]
  rm -f "$f"
}

@test "load_settings falls back to default betterdisplay_enabled on an invalid value" {
  local f; f="$(mktemp)"
  printf '%s' '{"betterdisplay_enabled":"maybe"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_betterdisplay_enabled" = "false" ]
  rm -f "$f"
}

@test "load_settings applies a partial override, leaving the rest at defaults" {
  local f; f="$(mktemp)"
  printf '%s' '{"muted_color":"#ABCDEF"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_muted_color" = "#ABCDEF" ]
  [ "$SETTING_icon_color" = "theme:primary" ]
  [ "$SETTING_region" = "right" ]
  rm -f "$f"
}

#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/clock.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_time_format" = "%H:%M:%S" ]
  [ "$SETTING_time_interval" = "1" ]
}

@test "load_settings applies color defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_label_color" = "theme:primary" ]
  [ "$SETTING_bg_color" = "theme:background" ]
}

@test "load_settings applies pill geometry defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_bg_height" = "" ]
}

@test "load_settings overrides from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"font":"MyFont","time_format":"%I:%M %p"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_font" = "MyFont" ]
  [ "$SETTING_time_format" = "%I:%M %p" ]
  [ "$SETTING_time_interval" = "1" ]  # untouched key keeps default
  rm -f "$f"
}

@test "load_settings falls back to default font on an empty override" {
  local f; f="$(mktemp)"
  printf '%s' '{"font":""}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  rm -f "$f"
}

@test "load_settings falls back to default time_format on an empty override" {
  local f; f="$(mktemp)"
  printf '%s' '{"time_format":""}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_time_format" = "%H:%M:%S" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent time_interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"time_interval":"%s"}' "$v" >"$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_time_interval" = "1" ] || { echo "time_interval=$v not rejected: got $SETTING_time_interval"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings falls back on a non-numeric time_interval" {
  local f; f="$(mktemp)"
  printf '%s' '{"time_interval":"abc"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_time_interval" = "1" ]
  rm -f "$f"
}

@test "load_settings keeps a valid time_interval override" {
  local f; f="$(mktemp)"
  printf '%s' '{"time_interval":"2"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_time_interval" = "2" ]
  rm -f "$f"
}

@test "load_settings falls back to empty corner_radius/bg_height on out-of-range or non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"31","bg_height":"15"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_bg_height" = "" ]
  rm -f "$f"
}

@test "load_settings keeps an explicit corner_radius override" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"12"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_corner_radius" = "12" ]
  rm -f "$f"
}

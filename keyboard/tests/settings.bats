#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/keyboard.sh"
}

@test "load_settings has interval default 1 and region default right" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_interval" = "1" ]
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_bg_color" = "theme:background" ]
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
}

@test "load_settings keeps an explicit corner_radius override" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"12"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_corner_radius" = "12" ]
  rm -f "$f"
}

@test "load_settings overrides from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"5","region":"left"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "5" ]
  [ "$SETTING_region" = "left" ]
  rm -f "$f"
}

@test "load_settings keeps a valid fractional interval like 0.5" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"0.5"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "0.5" ]
  rm -f "$f"
}

@test "load_settings falls back to interval default on non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "1" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"interval":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_interval" = "1" ] || { echo "interval=$v not rejected: got $SETTING_interval"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

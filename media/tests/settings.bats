#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/media.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_interval" = "3" ]
  [ "$SETTING_show_label" = "true" ]
  [ "$SETTING_label_max_length" = "30" ]
  [ "$SETTING_idle_icon" = "󰝚" ]
  [ "$SETTING_idle_color" = "theme:secondary" ]
  [ "$SETTING_playing_icon" = "󰏤" ]
  [ "$SETTING_playing_icon_color" = "theme:primary" ]
  [ "$SETTING_playing_bg_color" = "theme:background" ]
  [ "$SETTING_paused_icon" = "󰐊" ]
  [ "$SETTING_paused_icon_color" = "#12161D" ]
  [ "$SETTING_paused_bg_color" = "theme:warning" ]
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
  printf '%s' '{"interval":"5","show_label":"false","label_max_length":"50","idle_icon":"X","idle_color":"#000001","playing_icon":"Y","playing_icon_color":"#000002","playing_bg_color":"#000003","paused_icon":"Z","paused_icon_color":"#000004","paused_bg_color":"#000005"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "5" ]
  [ "$SETTING_show_label" = "false" ]
  [ "$SETTING_label_max_length" = "50" ]
  [ "$SETTING_idle_icon" = "X" ]
  [ "$SETTING_idle_color" = "#000001" ]
  [ "$SETTING_playing_icon" = "Y" ]
  [ "$SETTING_playing_icon_color" = "#000002" ]
  [ "$SETTING_playing_bg_color" = "#000003" ]
  [ "$SETTING_paused_icon" = "Z" ]
  [ "$SETTING_paused_icon_color" = "#000004" ]
  [ "$SETTING_paused_bg_color" = "#000005" ]
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
  [ "$SETTING_interval" = "3" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"interval":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_interval" = "3" ] || { echo "interval=$v not rejected: got $SETTING_interval"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings clamps label_max_length to its 5-100 range" {
  local f; f="$(mktemp)"
  printf '%s' '{"label_max_length":"200"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_label_max_length" = "30" ]
  rm -f "$f"

  printf '%s' '{"label_max_length":"2"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_label_max_length" = "30" ]

  printf '%s' '{"label_max_length":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_label_max_length" = "30" ]
  rm -f "$f"
}

@test "load_settings partial override keeps other defaults" {
  local f; f="$(mktemp)"
  printf '%s' '{"idle_color":"#ABCDEF"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_idle_color" = "#ABCDEF" ]
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_interval" = "3" ]
  rm -f "$f"
}

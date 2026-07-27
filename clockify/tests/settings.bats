#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/clockify.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_interval" = "30" ]
  [ "$SETTING_token_file" = "${HOME}/.config/sketchybar/.clockify_token" ]
  [ "$SETTING_max_rows" = "10" ]
  [ "$SETTING_request_timeout" = "8" ]
  [ "$SETTING_tracking_color" = "theme:success" ]
  [ "$SETTING_idle_color" = "theme:warning" ]
  [ "$SETTING_warn_color" = "theme:secondary" ]
  [ "$SETTING_icon_color" = "#12161D" ]
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_bg_height" = "" ]
}

@test "load_settings overrides from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"region":"left","interval":"60","token_file":"/tmp/mytoken","max_rows":"5","request_timeout":"15","tracking_color":"#111111","idle_color":"#222222","warn_color":"#333333","icon_color":"#444444"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_region" = "left" ]
  [ "$SETTING_interval" = "60" ]
  [ "$SETTING_token_file" = "/tmp/mytoken" ]
  [ "$SETTING_max_rows" = "5" ]
  [ "$SETTING_request_timeout" = "15" ]
  [ "$SETTING_tracking_color" = "#111111" ]
  [ "$SETTING_idle_color" = "#222222" ]
  [ "$SETTING_warn_color" = "#333333" ]
  [ "$SETTING_icon_color" = "#444444" ]
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

@test "load_settings falls back to default interval on non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "30" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"interval":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_interval" = "30" ] || { echo "interval=$v not rejected: got $SETTING_interval"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings keeps a valid interval override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"120"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "120" ]
  rm -f "$f"
}

@test "load_settings falls back to default max_rows on out-of-range or non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"max_rows":"11"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_rows" = "10" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"max_rows":"0"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_rows" = "10" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"max_rows":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_rows" = "10" ]
  rm -f "$f"
}

@test "load_settings accepts max_rows at the valid boundary" {
  local f; f="$(mktemp)"
  printf '%s' '{"max_rows":"1"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_rows" = "1" ]
  rm -f "$f"
}

@test "load_settings falls back to default request_timeout on out-of-range or non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"request_timeout":"31"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_request_timeout" = "8" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"request_timeout":"2"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_request_timeout" = "8" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"request_timeout":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_request_timeout" = "8" ]
  rm -f "$f"
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

@test "load_settings partial override keeps other defaults" {
  local f; f="$(mktemp)"
  printf '%s' '{"idle_color":"#ABCDEF"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_idle_color" = "#ABCDEF" ]
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_interval" = "30" ]
  [ "$SETTING_token_file" = "${HOME}/.config/sketchybar/.clockify_token" ]
  rm -f "$f"
}

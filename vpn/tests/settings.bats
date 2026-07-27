#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/vpn.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_interval" = "3" ]
  [ "$SETTING_warp_bin" = "/usr/local/bin/warp-cli" ]
  [ "$SETTING_status_timeout_seconds" = "5" ]
  [ "$SETTING_connected_color" = "theme:success" ]
  [ "$SETTING_warp_accent_color" = "theme:warning" ]
  [ "$SETTING_netbird_icon_color" = "#12161D" ]
  [ "$SETTING_off_color" = "theme:secondary" ]
  [ "$SETTING_unknown_color" = "theme:warning" ]
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_bg_height" = "" ]
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

@test "load_settings resolves netbird_bin via command -v with a homebrew fallback when unset" {
  local expected
  expected="$(command -v netbird 2>/dev/null || printf '/opt/homebrew/bin/netbird')"
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_netbird_bin" = "$expected" ]
}

@test "load_settings keeps an explicit netbird_bin override without resolving" {
  local f; f="$(mktemp)"
  printf '%s' '{"netbird_bin":"/custom/path/netbird"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_netbird_bin" = "/custom/path/netbird" ]
  rm -f "$f"
}

@test "load_settings keeps an explicit warp_bin override" {
  local f; f="$(mktemp)"
  printf '%s' '{"warp_bin":"/custom/path/warp-cli"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_warp_bin" = "/custom/path/warp-cli" ]
  rm -f "$f"
}

@test "load_settings overrides from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"connected_color":"#123456","off_color":"#654321"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_connected_color" = "#123456" ]
  [ "$SETTING_off_color" = "#654321" ]
  [ "$SETTING_unknown_color" = "theme:warning" ]   # untouched key keeps default
  rm -f "$f"
}

@test "load_settings falls back to default interval on non-numeric override" {
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

@test "load_settings keeps a valid interval override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"10"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "10" ]
  rm -f "$f"
}

@test "load_settings falls back to default status_timeout_seconds on out-of-range or non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"status_timeout_seconds":"31"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_status_timeout_seconds" = "5" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"status_timeout_seconds":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_status_timeout_seconds" = "5" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"status_timeout_seconds":"0"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_status_timeout_seconds" = "5" ]
  rm -f "$f"
}

@test "load_settings accepts status_timeout_seconds at the valid boundary" {
  local f; f="$(mktemp)"
  printf '%s' '{"status_timeout_seconds":"1"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_status_timeout_seconds" = "1" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"status_timeout_seconds":"30"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_status_timeout_seconds" = "30" ]
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

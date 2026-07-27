#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/weather.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_location" = "Szeged" ]
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_interval" = "1800" ]
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

@test "load_settings applies condition-color defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_thunder_color" = "theme:error" ]
  [ "$SETTING_snow_color" = "theme:primary" ]
  [ "$SETTING_sleet_color" = "theme:system" ]
  [ "$SETTING_rain_color" = "theme:system" ]
  [ "$SETTING_fog_color" = "theme:secondary" ]
  [ "$SETTING_overcast_color" = "theme:secondary" ]
  [ "$SETTING_cloud_color" = "theme:secondary" ]
  [ "$SETTING_sunny_color" = "theme:warning" ]
  [ "$SETTING_default_color" = "theme:system" ]
}

@test "load_settings applies background/highlight defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_label_color" = "theme:primary" ]
  [ "$SETTING_bg_color" = "theme:background" ]
  [ "$SETTING_rain_bg_color" = "theme:system" ]
  [ "$SETTING_storm_bg_color" = "theme:error" ]
  [ "$SETTING_highlight_text_color" = "#12161D" ]
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
  printf '%s' '{"location":"Budapest","region":"left"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_location" = "Budapest" ]
  [ "$SETTING_region" = "left" ]
  [ "$SETTING_interval" = "1800" ]  # untouched key keeps default
  rm -f "$f"
}

@test "load_settings falls back to Szeged on an empty location" {
  local f; f="$(mktemp)"
  printf '%s' '{"location":""}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_location" = "Szeged" ]
  rm -f "$f"
}

@test "load_settings keeps a valid interval override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"600"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "600" ]
  rm -f "$f"
}

@test "load_settings falls back to 1800 on a non-numeric interval" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"abc"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "1800" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"interval":"%s"}' "$v" >"$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_interval" = "1800" ] || { echo "interval=$v not rejected: got $SETTING_interval"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings keeps a valid fractional interval like 900.5" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"900.5"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "900.5" ]
  rm -f "$f"
}

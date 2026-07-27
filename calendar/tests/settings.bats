#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/calendar.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_date_format" = "%a %d/%m/%Y" ]
  [ "$SETTING_date_interval" = "30" ]
  [ "$SETTING_max_meetings" = "8" ]
  [ "$SETTING_calendar_app" = "BusyCal" ]
}

@test "load_settings applies color defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_label_color" = "theme:primary" ]
  [ "$SETTING_icon_color" = "theme:system" ]
  [ "$SETTING_bg_color" = "theme:background" ]
  [ "$SETTING_busy_bg_color" = "theme:warning" ]
  [ "$SETTING_busy_fg_color" = "#12161D" ]
  [ "$SETTING_popup_header_color" = "theme:system" ]
  [ "$SETTING_row_text_color" = "theme:primary" ]
  [ "$SETTING_row_icon_color" = "theme:secondary" ]
  [ "$SETTING_in_progress_color" = "theme:success" ]
}

@test "load_settings applies date_icon and pill geometry defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_date_icon" = "󰃭" ]
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_bg_height" = "" ]
}

@test "load_settings overrides from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"font":"MyFont","max_meetings":"5"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_font" = "MyFont" ]
  [ "$SETTING_max_meetings" = "5" ]
  [ "$SETTING_date_interval" = "30" ]  # untouched key keeps default
  rm -f "$f"
}

@test "load_settings falls back to default font on an empty override" {
  local f; f="$(mktemp)"
  printf '%s' '{"font":""}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  rm -f "$f"
}

@test "load_settings falls back to default calendar_app on an empty override" {
  local f; f="$(mktemp)"
  printf '%s' '{"calendar_app":""}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_calendar_app" = "BusyCal" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent date_interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"date_interval":"%s"}' "$v" >"$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_date_interval" = "30" ] || { echo "date_interval=$v not rejected: got $SETTING_date_interval"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings falls back on a non-numeric date_interval" {
  local f; f="$(mktemp)"
  printf '%s' '{"date_interval":"xyz"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_date_interval" = "30" ]
  rm -f "$f"
}

@test "load_settings keeps a valid date_interval override" {
  local f; f="$(mktemp)"
  printf '%s' '{"date_interval":"60"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_date_interval" = "60" ]
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

@test "load_settings falls back to default max_meetings on out-of-range or non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"max_meetings":"0"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_meetings" = "8" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"max_meetings":"21"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_meetings" = "8" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"max_meetings":"nope"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_meetings" = "8" ]
  rm -f "$f"
}

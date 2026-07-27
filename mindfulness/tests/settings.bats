#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/mindfulness.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_poll_counting" = "10" ]
  [ "$SETTING_poll_pulse" = "1" ]
  [ "$SETTING_poll_disabled" = "30" ]
  [ "$SETTING_default_interval" = "15" ]
  [ "$SETTING_default_volume" = "100" ]
  [ "$SETTING_enabled_color" = "theme:success" ]
  [ "$SETTING_disabled_color" = "theme:warning" ]
  [ "$SETTING_pulse_color" = "theme:error" ]
  [ "$SETTING_icon_color" = "#12161D" ]
  [ "$SETTING_bell_sound" = "/System/Library/Sounds/Submarine.aiff" ]
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
  printf '%s' '{"poll_counting":"20","default_interval":"25","default_volume":"50","enabled_color":"#123456"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_poll_counting" = "20" ]
  [ "$SETTING_default_interval" = "25" ]
  [ "$SETTING_default_volume" = "50" ]
  [ "$SETTING_enabled_color" = "#123456" ]
  [ "$SETTING_poll_pulse" = "1" ]   # untouched key keeps default
  rm -f "$f"
}

@test "load_settings falls back to defaults on non-numeric poll overrides" {
  local f; f="$(mktemp)"
  printf '%s' '{"poll_counting":"abc","poll_pulse":"abc","poll_disabled":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_poll_counting" = "10" ]
  [ "$SETTING_poll_pulse" = "1" ]
  [ "$SETTING_poll_disabled" = "30" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent poll_counting values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"poll_counting":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_poll_counting" = "10" ] || { echo "poll_counting=$v not rejected: got $SETTING_poll_counting"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings rejects zero-equivalent poll_pulse values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"poll_pulse":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_poll_pulse" = "1" ] || { echo "poll_pulse=$v not rejected: got $SETTING_poll_pulse"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings rejects zero-equivalent poll_disabled values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"poll_disabled":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_poll_disabled" = "30" ] || { echo "poll_disabled=$v not rejected: got $SETTING_poll_disabled"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings keeps a valid fractional poll_pulse like 0.5" {
  local f; f="$(mktemp)"
  printf '%s' '{"poll_pulse":"0.5"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_poll_pulse" = "0.5" ]
  rm -f "$f"
}

@test "load_settings falls back to defaults on out-of-range default_interval/default_volume" {
  local f; f="$(mktemp)"
  printf '%s' '{"default_interval":"0","default_volume":"101"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_default_interval" = "15" ]
  [ "$SETTING_default_volume" = "100" ]
  rm -f "$f"
}

@test "load_settings accepts default_interval/default_volume at the valid boundary" {
  local f; f="$(mktemp)"
  printf '%s' '{"default_interval":"1","default_volume":"0"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_default_interval" = "1" ]
  [ "$SETTING_default_volume" = "0" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"default_interval":"60","default_volume":"100"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_default_interval" = "60" ]
  [ "$SETTING_default_volume" = "100" ]
  rm -f "$f"
}

@test "load_settings partial override keeps other defaults" {
  local f; f="$(mktemp)"
  printf '%s' '{"bell_sound":"/tmp/bell.aiff"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_bell_sound" = "/tmp/bell.aiff" ]
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_default_interval" = "15" ]
  rm -f "$f"
}

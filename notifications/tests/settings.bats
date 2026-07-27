#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/notifications.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_interval" = "10" ]
  [ "$SETTING_target_item" = "clock.time" ]
  [ "$SETTING_tint_bg_color" = "theme:warning" ]
  [ "$SETTING_tint_label_color" = "#12161D" ]
  [ "$SETTING_normal_bg_color" = "theme:background" ]
  [ "$SETTING_normal_label_color" = "theme:primary" ]
}

@test "load_settings overrides target_item, falling back to the default on empty" {
  local f; f="$(mktemp)"
  printf '%s' '{"target_item":"my.clock"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_target_item" = "my.clock" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"target_item":""}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_target_item" = "clock.time" ]
  rm -f "$f"
}

@test "load_settings overrides colors from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"tint_bg_color":"#123456","normal_bg_color":"#654321"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_tint_bg_color" = "#123456" ]
  [ "$SETTING_normal_bg_color" = "#654321" ]
  [ "$SETTING_interval" = "10" ]   # untouched key keeps default
  rm -f "$f"
}

@test "load_settings falls back to default interval on non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "10" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"interval":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_interval" = "10" ] || { echo "interval=$v not rejected: got $SETTING_interval"; rm -f "$f"; return 1; }
    rm -f "$f"
  done
}

@test "load_settings keeps a valid interval override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"60"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "60" ]
  rm -f "$f"
}

@test "load_settings rejects malformed colors (argv-injection guard)" {
  local f; f="$(mktemp)"
  printf '%s' '{"tint_bg_color":"#FF9E64 --border-width 999","normal_bg_color":"red","tint_label_color":"#12345","normal_label_color":"#AABBCCDD"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  [ "$SETTING_tint_bg_color" = "theme:warning" ]     # embedded flags rejected
  [ "$SETTING_normal_bg_color" = "theme:background" ] # named color rejected
  [ "$SETTING_tint_label_color" = "#12161D" ] # wrong length rejected
  [ "$SETTING_normal_label_color" = "#AABBCCDD" ]    # 8-digit alpha accepted
}

@test "load_settings accepts theme: tokens for colors" {
  local f; f="$(mktemp)"
  printf '%s' '{"tint_bg_color":"theme:warning","normal_bg_color":"theme:custom-name"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  [ "$SETTING_tint_bg_color" = "theme:warning" ]
  [ "$SETTING_normal_bg_color" = "theme:custom-name" ]
}

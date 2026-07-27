#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/tasks.sh"
}

# Regression guard: an empty --icon at `ridge add` time never attaches an
# icon PART to the item, so a later `ridge set --icon-color ...` call fails
# with "item has no icon" - see the comment on TASKS_GLYPH and README.md.
@test "TASKS_GLYPH is non-empty" {
  [ -n "$TASKS_GLYPH" ]
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_interval" = "60" ]
  [ "$SETTING_things_enabled" = "true" ]
  [ "$SETTING_noteplan_enabled" = "true" ]
  [ "$SETTING_obsidian_enabled" = "true" ]
  [ "$SETTING_obsidian_vault" = "Notes" ]
  [ "$SETTING_obsidian_inbox_rel" = "Notes/00-INBOX" ]
  [ "$SETTING_max_rows" = "8" ]
  [ "$SETTING_icon_color" = "theme:primary" ]
  [ "$SETTING_empty_color" = "theme:secondary" ]
  [ "$SETTING_bg_color" = "theme:background" ]
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

@test "load_settings falls back noteplan_dir/obsidian_inbox_dir to bash-expanded HOME defaults when absent" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_noteplan_dir" = "${HOME}/Library/Containers/co.noteplan.NotePlan-setapp/Data/Library/Application Support/co.noteplan.NotePlan-setapp/Calendar" ]
  [ "$SETTING_obsidian_inbox_dir" = "${HOME}/Notes/Notes/00-INBOX" ]
  # Never a literal, unexpanded "$HOME" string and never empty.
  [[ "$SETTING_noteplan_dir" != *'$HOME'* ]]
  [[ "$SETTING_obsidian_inbox_dir" != *'$HOME'* ]]
  [ -n "$SETTING_noteplan_dir" ]
  [ -n "$SETTING_obsidian_inbox_dir" ]
}

@test "load_settings falls back noteplan_dir/obsidian_inbox_dir to HOME defaults on empty-string settings value" {
  local f; f="$(mktemp)"
  printf '%s' '{"noteplan_dir":"","obsidian_inbox_dir":""}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_noteplan_dir" = "${HOME}/Library/Containers/co.noteplan.NotePlan-setapp/Data/Library/Application Support/co.noteplan.NotePlan-setapp/Calendar" ]
  [ "$SETTING_obsidian_inbox_dir" = "${HOME}/Notes/Notes/00-INBOX" ]
  rm -f "$f"
}

@test "load_settings overrides from the settings JSON" {
  local f; f="$(mktemp)"
  printf '%s' '{"region":"left","things_enabled":"false","obsidian_vault":"MyVault","noteplan_dir":"/custom/np","obsidian_inbox_dir":"/custom/inbox"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_region" = "left" ]
  [ "$SETTING_things_enabled" = "false" ]
  [ "$SETTING_obsidian_vault" = "MyVault" ]
  [ "$SETTING_noteplan_dir" = "/custom/np" ]
  [ "$SETTING_obsidian_inbox_dir" = "/custom/inbox" ]
  [ "$SETTING_noteplan_enabled" = "true" ]   # untouched key keeps default
  rm -f "$f"
}

@test "load_settings overrides all three _enabled bools independently" {
  local f; f="$(mktemp)"
  printf '%s' '{"things_enabled":"false","noteplan_enabled":"false","obsidian_enabled":"false"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_things_enabled" = "false" ]
  [ "$SETTING_noteplan_enabled" = "false" ]
  [ "$SETTING_obsidian_enabled" = "false" ]
  rm -f "$f"
}

@test "load_settings falls back to true on an invalid _enabled value" {
  local f; f="$(mktemp)"
  printf '%s' '{"things_enabled":"maybe"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_things_enabled" = "true" ]
  rm -f "$f"
}

@test "load_settings falls back to default interval on non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"interval":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "60" ]
  rm -f "$f"
}

@test "load_settings rejects zero-equivalent interval values" {
  local v
  for v in "0" "00" "0.0" "0.00" ".0"; do
    local f; f="$(mktemp)"
    printf '{"interval":"%s"}' "$v" > "$f"
    RIDGE_PLUGIN_SETTINGS="$f" load_settings
    [ "$SETTING_interval" = "60" ] || { echo "interval=$v not rejected: got $SETTING_interval"; rm -f "$f"; return 1; }
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

@test "load_settings validates max_rows boundaries" {
  local f; f="$(mktemp)"
  printf '%s' '{"max_rows":"1"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_rows" = "1" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"max_rows":"20"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_rows" = "20" ]
  rm -f "$f"
}

@test "load_settings falls back to default max_rows on out-of-range or non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"max_rows":"0"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_rows" = "8" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"max_rows":"21"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_rows" = "8" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"max_rows":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_rows" = "8" ]
  rm -f "$f"
}

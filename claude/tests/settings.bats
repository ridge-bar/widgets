#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/claude.sh"
}

@test "load_settings applies defaults" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  [ "$SETTING_region" = "right" ]
  [ "$SETTING_font" = "Iosevka Nerd Font" ]
  [ "$SETTING_interval" = "10" ]
  [ "$SETTING_projects_dir" = "${HOME}/.claude/projects" ]
  [ "$SETTING_process_pattern" = "local/bin/claude" ]
  [ "$SETTING_idle_icon_color" = "theme:warning" ]
  [ "$SETTING_busy_icon_color" = "#12161D" ]
  [ "$SETTING_idle_bg_color" = "theme:background" ]
  [ "$SETTING_busy_bg_color" = "theme:success" ]
  [ "$SETTING_corner_radius" = "" ]
  [ "$SETTING_bg_height" = "" ]
  [ "$SETTING_max_sessions" = "5" ]
  [ "$SETTING_max_subagents" = "4" ]
  [ "$SETTING_cache_stale_seconds" = "300" ]
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
  printf '%s' '{"region":"left","process_pattern":"npm/bin/claude","busy_bg_color":"#123456"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_region" = "left" ]
  [ "$SETTING_process_pattern" = "npm/bin/claude" ]
  [ "$SETTING_busy_bg_color" = "#123456" ]
  [ "$SETTING_idle_bg_color" = "theme:background" ]   # untouched key keeps default
  rm -f "$f"
}

@test "load_settings applies a custom projects_dir override" {
  local f; f="$(mktemp)"
  printf '%s' '{"projects_dir":"/tmp/custom-claude-projects"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_projects_dir" = "/tmp/custom-claude-projects" ]
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
  printf '%s' '{"interval":"30"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_interval" = "30" ]
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

@test "load_settings falls back to default max_sessions/max_subagents on out-of-range override" {
  local f; f="$(mktemp)"
  printf '%s' '{"max_sessions":"11","max_subagents":"0"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_sessions" = "5" ]
  [ "$SETTING_max_subagents" = "4" ]
  rm -f "$f"
}

@test "load_settings accepts max_sessions/max_subagents at the valid boundary" {
  local f; f="$(mktemp)"
  printf '%s' '{"max_sessions":"1","max_subagents":"10"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_max_sessions" = "1" ]
  [ "$SETTING_max_subagents" = "10" ]
  rm -f "$f"
}

@test "load_settings falls back to default cache_stale_seconds on out-of-range or non-numeric override" {
  local f; f="$(mktemp)"
  printf '%s' '{"cache_stale_seconds":"10"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_cache_stale_seconds" = "300" ]
  rm -f "$f"

  f="$(mktemp)"
  printf '%s' '{"cache_stale_seconds":"abc"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_cache_stale_seconds" = "300" ]
  rm -f "$f"
}

@test "load_settings keeps a valid cache_stale_seconds override" {
  local f; f="$(mktemp)"
  printf '%s' '{"cache_stale_seconds":"600"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  [ "$SETTING_cache_stale_seconds" = "600" ]
  rm -f "$f"
}

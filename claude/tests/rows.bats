#!/usr/bin/env bats
# Exercises the pure functions in claude.sh: no I/O, no `ridge`/`find`/python
# invocations - callers pass already-read data.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/claude.sh"
}

# --- _claude_agent_short_id ---

@test "_claude_agent_short_id extracts the first 8 chars of the agent id" {
  run _claude_agent_short_id "/Users/dev/.claude/projects/x/subagents/agent-deadbeef1234abcd.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "deadbeef" ]
}

@test "_claude_agent_short_id handles a short id without truncation past its length" {
  run _claude_agent_short_id "/tmp/agent-abc.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "abc" ]
}

# --- _claude_working_state ---

@test "_claude_working_state is busy when working=1" {
  run _claude_working_state "1" "0"
  [ "$output" = "busy" ]
}

@test "_claude_working_state is busy when a subagent is live even if not working" {
  run _claude_working_state "0" "2"
  [ "$output" = "busy" ]
}

@test "_claude_working_state is idle when neither working nor a live subagent" {
  run _claude_working_state "0" "0"
  [ "$output" = "idle" ]
}

@test "_claude_working_state defaults to idle on empty inputs" {
  run _claude_working_state "" ""
  [ "$output" = "idle" ]
}

# --- _claude_cache_age_stale ---

@test "_claude_cache_age_stale is stale when age is negative (cache absent)" {
  run _claude_cache_age_stale "-1" "300"
  [ "$status" -eq 0 ]
}

@test "_claude_cache_age_stale is stale when age exceeds the threshold" {
  run _claude_cache_age_stale "301" "300"
  [ "$status" -eq 0 ]
}

@test "_claude_cache_age_stale is fresh when age is within the threshold" {
  run _claude_cache_age_stale "100" "300"
  [ "$status" -eq 1 ]
}

# --- _claude_session_rows_json ---

@test "_claude_session_rows_json returns an empty array for no data" {
  run _claude_session_rows_json "" "5" "#9ECE6A" "#FF9E64"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_claude_session_rows_json renders a working row with a green dot" {
  run _claude_session_rows_json $'working\tproj-a\t5m' "5" "#9ECE6A" "#FF9E64"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  [ "$(echo "$output" | jq 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.[0].icon')" = "●" ]
  [ "$(echo "$output" | jq -r '.[0].icon_color')" = "#9ECE6A" ]
  [ "$(echo "$output" | jq -r '.[0].text')" = "proj-a  ·  5m" ]
}

@test "_claude_session_rows_json renders a waiting row with an orange dot" {
  run _claude_session_rows_json $'waiting\tproj-b\t1h' "5" "#9ECE6A" "#FF9E64"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].icon')" = "○" ]
  [ "$(echo "$output" | jq -r '.[0].icon_color')" = "#FF9E64" ]
  [ "$(echo "$output" | jq -r '.[0].text')" = "proj-b  ·  1h" ]
}

@test "_claude_session_rows_json caps rows at max" {
  local data
  data="$(printf 'working\tproj-%s\t1m\n' 1 2 3 4 5 6 7)"
  run _claude_session_rows_json "$data" "3" "#9ECE6A" "#FF9E64"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "3" ]
}

# --- _claude_subagent_rows_json ---

@test "_claude_subagent_rows_json returns an empty array for no paths" {
  run _claude_subagent_rows_json "" "4" "#9ECE6A"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_claude_subagent_rows_json renders a green-dot row with the short agent id" {
  run _claude_subagent_rows_json "/tmp/x/subagents/agent-deadbeef1234abcd.jsonl" "4" "#9ECE6A"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.[0].icon')" = "●" ]
  [ "$(echo "$output" | jq -r '.[0].icon_color')" = "#9ECE6A" ]
  [ "$(echo "$output" | jq -r '.[0].text')" = "agent deadbeef" ]
}

@test "_claude_subagent_rows_json caps rows at max" {
  local paths
  paths="$(printf '/tmp/x/subagents/agent-%08d.jsonl\n' 1 2 3 4 5 6)"
  run _claude_subagent_rows_json "$paths" "4" "#9ECE6A"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "4" ]
}

# --- _claude_popup_rows_json ---

@test "_claude_popup_rows_json assembles title + session + subagent + token rows in order" {
  local sessions_json subagents_json
  sessions_json='[{"icon":"●","icon_color":"#9ECE6A","text":"proj-a  ·  5m"}]'
  subagents_json='[{"icon":"●","icon_color":"#9ECE6A","text":"agent deadbeef"}]'
  run _claude_popup_rows_json "$sessions_json" "$subagents_json" "12K" "34M" "56M"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
  [ "$(echo "$output" | jq 'length')" = "6" ]
  [ "$(echo "$output" | jq -r '.[0].icon')" = "Claude Code" ]
  [ "$(echo "$output" | jq -r '.[0].color')" = "#FF9E64" ]
  [ "$(echo "$output" | jq -r '.[1].text')" = "proj-a  ·  5m" ]
  [ "$(echo "$output" | jq -r '.[2].text')" = "agent deadbeef" ]
  [ "$(echo "$output" | jq -r '.[3].icon')" = "Tokens · 5h" ]
  [ "$(echo "$output" | jq -r '.[3].text')" = "12K" ]
  [ "$(echo "$output" | jq -r '.[4].icon')" = "Tokens · 24h" ]
  [ "$(echo "$output" | jq -r '.[4].text')" = "34M" ]
  [ "$(echo "$output" | jq -r '.[5].icon')" = "Tokens · 7d" ]
  [ "$(echo "$output" | jq -r '.[5].text')" = "56M" ]
}

@test "_claude_popup_rows_json handles empty session and subagent rows" {
  run _claude_popup_rows_json "[]" "[]" "0" "…" "…"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "4" ]
}

# --- _pill_flags ---

@test "_pill_flags emits the idle background/corner-radius/height flags" {
  SETTING_idle_bg_color="#292E42"
  SETTING_corner_radius="6"
  SETTING_bg_height="24"
  run _pill_flags
  [ "$status" -eq 0 ]
  [ "$output" = "--bg-color #292E42 --bg-corner-radius 6 --bg-height 24" ]
}

@test "_pill_flags omits --bg-height when unset (pill height auto-adapts to the bar)" {
  SETTING_idle_bg_color="#292E42"
  SETTING_corner_radius="6"
  SETTING_bg_height=""
  run _pill_flags
  [ "$status" -eq 0 ]
  [ "$output" = "--bg-color #292E42 --bg-corner-radius 6" ]
}

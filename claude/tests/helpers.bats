#!/usr/bin/env bats
# Runs the vendored claude_working.py / claude_sessions.py / claude_tokens.py
# against fixture transcripts and asserts their stdout. claude_working.py and
# claude_sessions.py rank/age candidates by the transcript *file's* mtime (not
# the JSON "timestamp" field), so each test copies fixtures into a scratch dir
# and sets explicit mtimes for determinism.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures/transcripts"
  WORKDIR="$(mktemp -d)"
  cp "${FIXTURES}/waiting-session.jsonl" "${WORKDIR}/waiting-session.jsonl"
  cp "${FIXTURES}/working-session.jsonl" "${WORKDIR}/working-session.jsonl"
  cp "${FIXTURES}/large-token-session.jsonl" "${WORKDIR}/large-token-session.jsonl"
}

teardown() {
  rm -rf "$WORKDIR"
}

# --- claude_working.py ---

@test "claude_working.py prints 0 when the only candidate ends on an assistant end_turn" {
  run bash -c "printf '%s\n' '${WORKDIR}/waiting-session.jsonl' | python3 '${PLUGIN_DIR}/claude_working.py' 1"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "claude_working.py prints 1 when the only candidate ends on a user message" {
  run bash -c "printf '%s\n' '${WORKDIR}/working-session.jsonl' | python3 '${PLUGIN_DIR}/claude_working.py' 1"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "claude_working.py prints 1 if any of the N most-recent candidates is working" {
  run bash -c "printf '%s\n%s\n' '${WORKDIR}/waiting-session.jsonl' '${WORKDIR}/working-session.jsonl' | python3 '${PLUGIN_DIR}/claude_working.py' 2"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "claude_working.py prints 0 for empty stdin or N<=0" {
  run bash -c "printf '' | python3 '${PLUGIN_DIR}/claude_working.py' 1"
  [ "$output" = "0" ]
  run bash -c "printf '%s\n' '${WORKDIR}/working-session.jsonl' | python3 '${PLUGIN_DIR}/claude_working.py' 0"
  [ "$output" = "0" ]
}

# --- claude_sessions.py ---

@test "claude_sessions.py reports waiting state and project name for an end_turn transcript" {
  run bash -c "printf '%s\n' '${WORKDIR}/waiting-session.jsonl' | python3 '${PLUGIN_DIR}/claude_sessions.py' 1"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^waiting$'\t'project-a$'\t'[0-9]+s$ ]]
}

@test "claude_sessions.py reports working state and project name for a mid-turn transcript" {
  run bash -c "printf '%s\n' '${WORKDIR}/working-session.jsonl' | python3 '${PLUGIN_DIR}/claude_sessions.py' 1"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^working$'\t'project-b$'\t'[0-9]+s$ ]]
}

@test "claude_sessions.py orders candidates most-recently-modified first" {
  # Uses /bin/date explicitly: this plugin is macOS-only (see claude.sh's
  # `stat -f %m`), but a Nix/devbox shell can put GNU coreutils' `date` first
  # on PATH, which does not understand BSD's `-v` flag.
  touch -t "$(/bin/date -v-10M +%Y%m%d%H%M.%S)" "${WORKDIR}/working-session.jsonl"
  touch -t "$(/bin/date -v-1M +%Y%m%d%H%M.%S)" "${WORKDIR}/waiting-session.jsonl"
  run bash -c "printf '%s\n%s\n' '${WORKDIR}/working-session.jsonl' '${WORKDIR}/waiting-session.jsonl' | python3 '${PLUGIN_DIR}/claude_sessions.py' 2"
  [ "$status" -eq 0 ]
  first_line="$(echo "$output" | sed -n 1p)"
  second_line="$(echo "$output" | sed -n 2p)"
  [[ "$first_line" == waiting$'\t'project-a$'\t'* ]]
  [[ "$second_line" == working$'\t'project-b$'\t'* ]]
}

@test "claude_sessions.py prints at most N lines" {
  run bash -c "printf '%s\n%s\n' '${WORKDIR}/waiting-session.jsonl' '${WORKDIR}/working-session.jsonl' | python3 '${PLUGIN_DIR}/claude_sessions.py' 1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "1" ]
}

# --- claude_tokens.py ---

@test "claude_tokens.py sums real-work tokens (excluding cache_read) across candidates in a wide window" {
  run bash -c "printf '%s\n%s\n' '${WORKDIR}/waiting-session.jsonl' '${WORKDIR}/working-session.jsonl' | python3 '${PLUGIN_DIR}/claude_tokens.py' 999999999999"
  [ "$status" -eq 0 ]
  # waiting: 100+50+10=160 (5000 cache_read excluded); working: 20+10+0=30. Total 190.
  [ "$output" = "190" ]
}

@test "claude_tokens.py excludes messages older than the window" {
  run bash -c "printf '%s\n' '${WORKDIR}/waiting-session.jsonl' | python3 '${PLUGIN_DIR}/claude_tokens.py' 1"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "claude_tokens.py abbreviates a multi-million total" {
  run bash -c "printf '%s\n' '${WORKDIR}/large-token-session.jsonl' | python3 '${PLUGIN_DIR}/claude_tokens.py' 999999999999"
  [ "$status" -eq 0 ]
  # 2,000,000 + 500,000 + 500,000 = 3,000,000 (the 999,999,999 cache_read is excluded).
  [ "$output" = "3M" ]
}

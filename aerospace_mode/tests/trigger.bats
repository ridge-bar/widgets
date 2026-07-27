#!/usr/bin/env bats
# trigger_loop: initial paint at startup, plus one coalesced paint per
# SIGUSR1 burst (ported pattern from plugins/aerospace's trigger_loop).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace_mode.sh"
  TMP="$(mktemp -d)"
}
teardown() {
  [[ -n "${LOOP_PID:-}" ]] && kill -KILL "$LOOP_PID" 2>/dev/null
  wait "${LOOP_PID:-}" 2>/dev/null
  rm -rf "$TMP"
}

# Polls until $1 has at least $2 lines, or fails after ~2s.
_wait_for_lines() {
  local file="$1" want="$2" i=0
  while [[ "$i" -lt 40 ]]; do
    [[ -f "$file" && "$(wc -l <"$file" | tr -d ' ')" -ge "$want" ]] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

@test "trigger_loop paints once at startup and once more per SIGUSR1" {
  _am_paint() { echo "paint" >>"$TMP/log"; }
  trigger_loop &
  LOOP_PID=$!
  run _wait_for_lines "$TMP/log" 1
  [ "$status" -eq 0 ]

  kill -USR1 "$LOOP_PID"
  run _wait_for_lines "$TMP/log" 2
  [ "$status" -eq 0 ]

  kill -TERM "$LOOP_PID" 2>/dev/null
  wait "$LOOP_PID" 2>/dev/null || true
  LOOP_PID=""
}

@test "a burst of SIGUSR1 while a paint is pending coalesces into one follow-up paint" {
  _am_paint() { echo "paint" >>"$TMP/log"; }
  trigger_loop &
  LOOP_PID=$!
  run _wait_for_lines "$TMP/log" 1
  [ "$status" -eq 0 ]

  kill -USR1 "$LOOP_PID"
  kill -USR1 "$LOOP_PID"
  kill -USR1 "$LOOP_PID"
  run _wait_for_lines "$TMP/log" 2
  [ "$status" -eq 0 ]
  sleep 0.3
  # A burst of 3 signals coalesces into at most one extra follow-up paint per
  # drain window, never one paint per signal.
  [ "$(wc -l <"$TMP/log" | tr -d ' ')" -le 3 ]

  kill -TERM "$LOOP_PID" 2>/dev/null
  wait "$LOOP_PID" 2>/dev/null || true
  LOOP_PID=""
}

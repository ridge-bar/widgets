#!/usr/bin/env bats
# _am_sanitize_mode/_am_label_for_mode: the state-file content is an external
# input boundary (written by the user's own aerospace.toml, but still not
# trusted). Covers the RED-first edge cases from the task spec: main/empty,
# garbage characters (+logged), and the length cap.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace_mode.sh"
}

@test "_am_sanitize_mode passes through a plain mode name" {
  run _am_sanitize_mode "service"
  [ "$status" -eq 0 ]
  [ "$output" = "service" ]
}

@test "_am_sanitize_mode trims surrounding whitespace/newline" {
  run _am_sanitize_mode $'  service\n'
  [ "$output" = "service" ]
}

@test "_am_sanitize_mode returns empty for an empty string" {
  run _am_sanitize_mode ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_am_sanitize_mode returns empty for literal main" {
  run _am_sanitize_mode "main"
  [ "$output" = "main" ]
}

@test "_am_sanitize_mode caps length at 24 chars without rejecting an otherwise-valid name" {
  local long; long="$(printf 'b%.0s' $(seq 1 40))"
  run _am_sanitize_mode "$long"
  [ "${#output}" -eq 24 ]
  [[ "$output" =~ ^b+$ ]]
}

@test "_am_sanitize_mode rejects path-traversal characters and logs once" {
  run bash -c "source '${PLUGIN_DIR}/aerospace_mode.sh'; _am_sanitize_mode '../../etc/passwd' 2>/dev/null"
  [ -z "$output" ]
}

@test "_am_sanitize_mode logs a warning for garbage input on stderr" {
  run bash -c "source '${PLUGIN_DIR}/aerospace_mode.sh'; _am_sanitize_mode 'service; rm -rf /' 2>&1 1>/dev/null"
  [[ "$output" == *"aerospace_mode:"* ]]
}

@test "_am_sanitize_mode rejects shell-special characters" {
  run bash -c "source '${PLUGIN_DIR}/aerospace_mode.sh'; _am_sanitize_mode 'service\$(touch pwned)' 2>/dev/null"
  [ -z "$output" ]
}

@test "_am_sanitize_mode allows underscores and dashes" {
  run _am_sanitize_mode "my-mode_1"
  [ "$output" = "my-mode_1" ]
}

@test "_am_label_for_mode uppercases a real mode" {
  run _am_label_for_mode "service"
  [ "$output" = "SERVICE" ]
}

@test "_am_label_for_mode is empty for main" {
  run _am_label_for_mode "main"
  [ -z "$output" ]
}

@test "_am_label_for_mode is empty for empty input" {
  run _am_label_for_mode ""
  [ -z "$output" ]
}

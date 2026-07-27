#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/amphetamine.sh"
}

@test "is_active is true when an Amphetamine assertion line is present" {
  _ask_session_active() { printf ''; }  # force pmset fallback
  _pmset_assertions() {
    cat <<'EOF'
Assertion status system-wide:
   BackgroundTask                     0
   ApplePushServiceTask                0
   UserIsActive                       1
   PreventUserIdleDisplaySleep(2)      (00:00:12) id: 12345 [pid: 111](Amphetamine)     "Amphetamine: Prevent Display Sleep"
Listed by owning process:
EOF
  }
  run is_active
  [ "$status" -eq 0 ]
}

@test "is_active is false when no Amphetamine assertion line is present" {
  _ask_session_active() { printf ''; }  # force pmset fallback
  _pmset_assertions() {
    cat <<'EOF'
Assertion status system-wide:
   BackgroundTask                     0
   ApplePushServiceTask                0
   UserIsActive                       1
Listed by owning process:
EOF
  }
  run is_active
  [ "$status" -eq 1 ]
}

@test "is_active ignores an Amphetamine assertion line that isn't a Prevent* type" {
  _ask_session_active() { printf ''; }  # force pmset fallback
  _pmset_assertions() {
    cat <<'EOF'
Assertion status system-wide:
   SomeOtherAssertionType(1)          (00:00:01) id: 999 [pid: 222](Amphetamine)     "Amphetamine: some other assertion"
Listed by owning process:
EOF
  }
  run is_active
  [ "$status" -eq 1 ]
}

@test "is_active ignores a Prevent* assertion line owned by a different process" {
  _ask_session_active() { printf ''; }  # force pmset fallback
  _pmset_assertions() {
    cat <<'EOF'
Assertion status system-wide:
   PreventUserIdleDisplaySleep(1)      (00:00:05) id: 42 [pid: 333](caffeinate)     "caffeinate command-line tool"
Listed by owning process:
EOF
  }
  run is_active
  [ "$status" -eq 1 ]
}

@test "_parse_session_active maps the AppleScript boolean result" {
  [ "$(_parse_session_active 'true')" = "active" ]
  [ "$(_parse_session_active 'false')" = "inactive" ]
  [ "$(_parse_session_active '')" = "" ]
  [ "$(_parse_session_active 'execution error: Not authorized')" = "" ]
}

#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/keyboard.sh"
}

@test "read_layout uses the TIS helper output when available" {
  _kb_helper() { printf '/fake/helper'; }
  # stub the helper binary invocation: bash calls "$helper", so shadow it via a
  # function isn't possible for an absolute path; instead stub _kb_helper to a
  # command that prints the id, using a wrapper.
  _kb_helper() { printf '%s' "$BATS_TEST_TMPDIR/h"; }
  cat > "$BATS_TEST_TMPDIR/h" <<'SH'
#!/bin/bash
printf 'com.apple.keylayout.Hungarian-QWERTY'
SH
  chmod +x "$BATS_TEST_TMPDIR/h"
  defaults() { printf 'com.apple.keylayout.USExtended'; }   # must NOT be used
  [ "$(read_layout)" = "com.apple.keylayout.Hungarian-QWERTY" ]
}

@test "read_layout falls back to defaults when no helper is available" {
  _kb_helper() { return 0; }   # prints nothing -> no helper
  defaults() { printf 'com.apple.keylayout.USExtended'; }
  [ "$(read_layout)" = "com.apple.keylayout.USExtended" ]
}

@test "read_layout falls back to defaults when the helper prints nothing" {
  _kb_helper() { printf '%s' "$BATS_TEST_TMPDIR/empty"; }
  printf '#!/bin/bash\n' > "$BATS_TEST_TMPDIR/empty"; chmod +x "$BATS_TEST_TMPDIR/empty"
  defaults() { printf 'com.apple.keylayout.USExtended'; }
  [ "$(read_layout)" = "com.apple.keylayout.USExtended" ]
}

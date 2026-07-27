#!/usr/bin/env bats

# _read_volume glues the osascript/BetterDisplay/cache reads together. A
# transient empty osascript result (timeout/failure under load) must be
# treated as "no reading" so the last-known cache wins - never displayed as a
# genuine 0%. See volume-zero-percent-investigation.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/volume.sh"
  export XDG_STATE_HOME="${BATS_TEST_TMPDIR}/state"
  SETTING_betterdisplay_enabled="false"
  SETTING_betterdisplay_name=""
  # Run the command directly (no perl alarm) so the osascript stub below is used.
  _timeout() { shift; "$@"; }
}

@test "_read_volume falls back to cache when osascript returns empty" {
  osascript() { printf ''; }
  _state_write last_volume_mute "50 0"
  run _read_volume
  [ "$output" = "$(printf '50\t0\tcache')" ]
}

@test "_read_volume yields empty pct (source none) on empty osascript with no cache" {
  osascript() { printf ''; }
  run _read_volume
  [ "$output" = "$(printf '\t0\tnone')" ]
}

@test "_read_volume reports a genuine live reading as internal" {
  osascript() { printf '50|false'; }
  run _read_volume
  [ "$output" = "$(printf '50\t0\tinternal')" ]
}

@test "_read_volume reports a genuine zero volume as internal" {
  osascript() { printf '0|false'; }
  run _read_volume
  [ "$output" = "$(printf '0\t0\tinternal')" ]
}

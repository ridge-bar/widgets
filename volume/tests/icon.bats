#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  # Sourcing must NOT start the poll loop.
  source "${PLUGIN_DIR}/volume.sh"
}

@test "_volume_icon: muted overrides the band regardless of percent" {
  run _volume_icon 80 1 L M H MU
  [ "$output" = "MU" ]
  run _volume_icon 100 1 L M H MU
  [ "$output" = "MU" ]
}

@test "_volume_icon: 0 percent uses the muted icon even when not muted" {
  run _volume_icon 0 0 L M H MU
  [ "$output" = "MU" ]
}

@test "_volume_icon: low band at or below 33" {
  run _volume_icon 1 0 L M H MU
  [ "$output" = "L" ]
  run _volume_icon 33 0 L M H MU
  [ "$output" = "L" ]
}

@test "_volume_icon: mid band 34-66" {
  run _volume_icon 34 0 L M H MU
  [ "$output" = "M" ]
  run _volume_icon 66 0 L M H MU
  [ "$output" = "M" ]
}

@test "_volume_icon: high band above 66" {
  run _volume_icon 67 0 L M H MU
  [ "$output" = "H" ]
  run _volume_icon 100 0 L M H MU
  [ "$output" = "H" ]
}

@test "_volume_color: muted uses muted_color regardless of percent" {
  run _volume_color 1 50 "#ICON" "#MUTED"
  [ "$output" = "#MUTED" ]
  run _volume_color 1 100 "#ICON" "#MUTED"
  [ "$output" = "#MUTED" ]
}

@test "_volume_color: 0 percent uses muted_color even when not muted" {
  run _volume_color 0 0 "#ICON" "#MUTED"
  [ "$output" = "#MUTED" ]
}

@test "_volume_color: unmuted non-zero percent uses icon_color" {
  run _volume_color 0 1 "#ICON" "#MUTED"
  [ "$output" = "#ICON" ]
  run _volume_color 0 100 "#ICON" "#MUTED"
  [ "$output" = "#ICON" ]
}

@test "_volume_mute_label: reflects the passed mute state" {
  run _volume_mute_label 1
  [ "$output" = "Unmute" ]
  run _volume_mute_label 0
  [ "$output" = "Mute" ]
}

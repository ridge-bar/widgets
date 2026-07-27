#!/usr/bin/env bats
# Table tests for the pure state-machine functions: (state, now) -> result.
# No file I/O, no `date` calls - every value below is hand-picked.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/mindfulness.sh"
}

# --- _mindfulness_phase -----------------------------------------------------

@test "_mindfulness_phase is disabled when enabled != 1, regardless of timing" {
  run _mindfulness_phase 0 1000 15 1000
  [ "$output" = "disabled" ]
  run _mindfulness_phase "garbage" 0 15 999999
  [ "$output" = "disabled" ]
}

@test "_mindfulness_phase is counting just before the interval boundary" {
  # 15 min interval = 900s; now - cycle_start = 899 -> still counting
  run _mindfulness_phase 1 1000 15 1899
  [ "$output" = "counting" ]
}

@test "_mindfulness_phase is overdue exactly at the interval boundary" {
  # now - cycle_start = 900 == 15*60 -> overdue (>=)
  run _mindfulness_phase 1 1000 15 1900
  [ "$output" = "overdue" ]
}

@test "_mindfulness_phase is overdue well past the interval boundary" {
  run _mindfulness_phase 1 1000 15 5000
  [ "$output" = "overdue" ]
}

@test "_mindfulness_phase is counting at cycle start (elapsed 0)" {
  run _mindfulness_phase 1 1000 15 1000
  [ "$output" = "counting" ]
}

@test "_mindfulness_phase handles a 1-minute interval boundary" {
  run _mindfulness_phase 1 0 1 59
  [ "$output" = "counting" ]
  run _mindfulness_phase 1 0 1 60
  [ "$output" = "overdue" ]
}

# --- _mindfulness_remaining --------------------------------------------------

@test "_mindfulness_remaining counts down toward the interval boundary" {
  run _mindfulness_remaining 1000 15 1000
  [ "$output" = "900" ]
  run _mindfulness_remaining 1000 15 1899
  [ "$output" = "1" ]
}

@test "_mindfulness_remaining is 0 exactly at the boundary" {
  run _mindfulness_remaining 1000 15 1900
  [ "$output" = "0" ]
}

@test "_mindfulness_remaining clamps to 0 past the boundary" {
  run _mindfulness_remaining 1000 15 999999
  [ "$output" = "0" ]
}

# --- _mindfulness_fmt_remaining ----------------------------------------------

@test "_mindfulness_fmt_remaining formats minutes and seconds" {
  run _mindfulness_fmt_remaining 432   # 7m 12s
  [ "$output" = "7m 12s" ]
}

@test "_mindfulness_fmt_remaining zero-pads single-digit seconds" {
  run _mindfulness_fmt_remaining 65    # 1m 05s
  [ "$output" = "1m 05s" ]
}

@test "_mindfulness_fmt_remaining handles exactly 0" {
  run _mindfulness_fmt_remaining 0
  [ "$output" = "0m 00s" ]
}

@test "_mindfulness_fmt_remaining clamps a negative value to 0" {
  run _mindfulness_fmt_remaining -30
  [ "$output" = "0m 00s" ]
}

# --- _mindfulness_pulse_on ---------------------------------------------------

@test "_mindfulness_pulse_on alternates on wall-clock parity" {
  run _mindfulness_pulse_on 1000   # even
  [ "$output" = "0" ]
  run _mindfulness_pulse_on 1001   # odd
  [ "$output" = "1" ]
  run _mindfulness_pulse_on 1002   # even again
  [ "$output" = "0" ]
}

# --- _mindfulness_click_action -----------------------------------------------

@test "_mindfulness_click_action: left click on disabled enables" {
  run _mindfulness_click_action left disabled
  [ "$output" = "enable" ]
}

@test "_mindfulness_click_action: left click on counting disables" {
  run _mindfulness_click_action left counting
  [ "$output" = "disable" ]
}

@test "_mindfulness_click_action: left click on overdue always shows (re-shows) the reminder" {
  run _mindfulness_click_action left overdue
  [ "$output" = "show_reminder" ]
}

@test "_mindfulness_click_action: right click always opens settings" {
  run _mindfulness_click_action right disabled
  [ "$output" = "settings" ]
  run _mindfulness_click_action right counting
  [ "$output" = "settings" ]
  run _mindfulness_click_action right overdue
  [ "$output" = "settings" ]
}

@test "_mindfulness_click_action: unknown button is a noop" {
  run _mindfulness_click_action middle counting
  [ "$output" = "noop" ]
}

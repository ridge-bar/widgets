#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/battery.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  PMSET_DISCHARGING="$(cat "${FIX}/pmset_discharging.txt")"
  PMSET_CHARGING="$(cat "${FIX}/pmset_charging.txt")"
  PMSET_CHARGED="$(cat "${FIX}/pmset_charged.txt")"
  PMSET_FINISHING="$(cat "${FIX}/pmset_finishing.txt")"
  PMSET_NO_ESTIMATE="$(cat "${FIX}/pmset_no_estimate.txt")"
  IOREG_SAMPLE="$(cat "${FIX}/ioreg_sample.txt")"
  IOREG_MISSING="$(cat "${FIX}/ioreg_missing.txt")"
}

@test "_battery_pct reads the percent from pmset output" {
  run _battery_pct "$PMSET_DISCHARGING"
  [ "$output" = "62" ]
  run _battery_pct "$PMSET_CHARGED"
  [ "$output" = "100" ]
}

@test "_battery_pct is empty when no percent is present" {
  run _battery_pct "no battery data here"
  [ -z "$output" ]
}

@test "_battery_on_ac is 1 on AC power, 0 on battery" {
  run _battery_on_ac "$PMSET_CHARGING"
  [ "$output" = "1" ]
  run _battery_on_ac "$PMSET_DISCHARGING"
  [ "$output" = "0" ]
}

@test "_battery_status extracts each known status word" {
  run _battery_status "$PMSET_DISCHARGING"
  [ "$output" = "discharging" ]
  run _battery_status "$PMSET_CHARGING"
  [ "$output" = "charging" ]
  run _battery_status "$PMSET_CHARGED"
  [ "$output" = "charged" ]
  run _battery_status "$PMSET_FINISHING"
  [ "$output" = "finishing charge" ]
}

@test "_battery_status falls back to a dash when absent" {
  run _battery_status "nothing matches here"
  [ "$output" = "-" ]
}

@test "_battery_time_left extracts H:MM remaining" {
  run _battery_time_left "$PMSET_DISCHARGING"
  [ "$output" = "3:45" ]
  run _battery_time_left "$PMSET_CHARGING"
  [ "$output" = "1:23" ]
}

@test "_battery_time_left falls back to a dash when pmset has no estimate" {
  run _battery_time_left "$PMSET_NO_ESTIMATE"
  [ "$output" = "-" ]
}

@test "_battery_power_source reports AC Power or Battery" {
  run _battery_power_source "$PMSET_CHARGING"
  [ "$output" = "AC Power" ]
  run _battery_power_source "$PMSET_DISCHARGING"
  [ "$output" = "Battery" ]
}

@test "_battery_cycles reads CycleCount from ioreg output" {
  run _battery_cycles "$IOREG_SAMPLE"
  [ "$output" = "342" ]
}

@test "_battery_cycles falls back to a dash when missing" {
  run _battery_cycles "$IOREG_MISSING"
  [ "$output" = "-" ]
}

@test "_battery_health computes AppleRawMaxCapacity/DesignCapacity as a percent" {
  run _battery_health "$IOREG_SAMPLE"
  # 4830 / 5017 * 100 = 96.27 -> rounds to 96%
  [ "$output" = "96%" ]
}

@test "_battery_health falls back to a dash when DesignCapacity is missing" {
  run _battery_health "$IOREG_MISSING"
  [ "$output" = "-" ]
}

@test "_battery_temp converts centi-degrees to Celsius" {
  run _battery_temp "$IOREG_SAMPLE"
  [ "$output" = "31.2C" ]
}

@test "_battery_temp falls back to a dash when Temperature is missing" {
  run _battery_temp "$IOREG_MISSING"
  [ "$output" = "-" ]
}

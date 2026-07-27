#!/usr/bin/env bats
# _cpu_delta_pct: (cs_now - cs_prev) / dt * 100, clamped at 0; falls
# back to pcpu when dt is stale (<=0 or >10).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/cpu.sh"
}

@test "computes the instantaneous delta over dt seconds" {
  # (110 - 100) / 5 * 100 = 200.0
  run _cpu_delta_pct 110 100 5 3.0
  [ "$output" = "200.0" ]
}

@test "clamps a negative delta (cs went backwards) to zero" {
  run _cpu_delta_pct 100 105 5 1.5
  [ "$output" = "0.0" ]
}

@test "falls back to pcpu when dt is zero (no elapsed time)" {
  run _cpu_delta_pct 100 100 0 12.3
  [ "$output" = "12.3" ]
}

@test "falls back to pcpu when dt is negative" {
  run _cpu_delta_pct 100 100 -3 8.0
  [ "$output" = "8.0" ]
}

@test "falls back to pcpu when dt exceeds 10 seconds (stale snapshot)" {
  run _cpu_delta_pct 500 100 11 4.5
  [ "$output" = "4.5" ]
}

@test "uses the delta path at the dt=10 boundary" {
  # dt=10 is not stale (only dt > 10 is); (150 - 100) / 10 * 100 = 500.0
  run _cpu_delta_pct 150 100 10 1.0
  [ "$output" = "500.0" ]
}

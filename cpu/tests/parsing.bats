#!/usr/bin/env bats
# _cpu_pct against a captured-style iostat fixture.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/cpu.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  IOSTAT_SAMPLE="$(cat "${FIX}/iostat_sample.txt")"
}

@test "_cpu_pct sums us+sy from the final iostat line, rounded" {
  # Final line: us=15 sy=8 -> 15 + 8 + 0.5 = 23.5 -> truncates to 23.
  run _cpu_pct "$IOSTAT_SAMPLE"
  [ "$output" = "23" ]
}

@test "_cpu_pct finds us+sy regardless of how many disks iostat reports" {
  # Regression: the columns were read at fixed positions ($4/$5), which only
  # hold on a single-disk machine. With three disks us/sy sit at $10/$11 and
  # $4/$5 are a disk's KB/t and tps - both 0 - so CPU always read 0 and the bar
  # froze at its lowest block. Final line here: us=33 sy=6 -> 39.
  run _cpu_pct "$(cat "${FIX}/iostat_multidisk.txt")"
  [ "$output" = "39" ]
}

@test "_cpu_popup_rows_json leads with a single summary header" {
  run _cpu_popup_rows_json "$(printf '12.5\tSafari')" 27 8.61
  [ "$status" -eq 0 ]
  local head; head="$(jq -r '.[0].text' <<<"$output")"
  [[ "$head" == *"27%"* ]]
  [[ "$head" == *"load 8.61"* ]]
  # one header, not a summary row stacked under a second "Top CPU" header
  [ "$(jq '[.[]|select(.type=="header")]|length' <<<"$output")" = "1" ]
  [ "$(jq -r '.[1].text' <<<"$output")" = "Safari" ]
}

@test "_cpu_popup_rows_json shows a placeholder until the first sample lands" {
  run _cpu_popup_rows_json "$(printf '12.5\tSafari')"
  [[ "$(jq -r '.[0].text' <<<"$output")" == *"measuring"* ]]
}

@test "_cpu_load reads the 1m average regardless of disk count" {
  run _cpu_load "$(cat "${FIX}/iostat_multidisk.txt")"
  [ "$output" = "5.27" ]
}

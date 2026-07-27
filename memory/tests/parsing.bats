#!/usr/bin/env bats
# _mem_pct against a captured-style vm_stat fixture.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/memory.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  VM_STAT_SAMPLE="$(cat "${FIX}/vm_stat_sample.txt")"
}

@test "_mem_pct computes (active+wired+comp)*pagesize/total*100, rounded" {
  # active=600000 wired=300000 comp=148576 -> sum 1048576 * 4096 / 8589934592
  # = 0.5 -> 50% exactly (+0.5 rounding truncates 50.5 to 50).
  run _mem_pct "$VM_STAT_SAMPLE" 8589934592 4096
  [ "$output" = "50" ]
}

@test "_mem_pct is empty when total is zero" {
  run _mem_pct "$VM_STAT_SAMPLE" 0 4096
  [ -z "$output" ]
}

@test "_mem_popup_rows_json leads with a single summary header in real units" {
  run _mem_popup_rows_json "$(printf '1.2G\tSafari')" 73 68719476736
  [ "$status" -eq 0 ]
  local head; head="$(jq -r '.[0].text' <<<"$output")"
  [[ "$head" == *"73%"* ]]
  [[ "$head" == *"64.0G"* ]]
  [ "$(jq '[.[]|select(.type=="header")]|length' <<<"$output")" = "1" ]
}

@test "_mem_popup_rows_json still reports the used share without a total" {
  run _mem_popup_rows_json "$(printf '1.2G\tSafari')" 73
  [[ "$(jq -r '.[0].text' <<<"$output")" == *"73%"* ]]
}

@test "_mem_popup_rows_json shows a placeholder until the first sample lands" {
  run _mem_popup_rows_json "$(printf '1.2G\tSafari')"
  [[ "$(jq -r '.[0].text' <<<"$output")" == *"measuring"* ]]
}

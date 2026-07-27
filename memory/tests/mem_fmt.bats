#!/usr/bin/env bats
# _mem_fmt: RSS (KB) -> human size, "X.XG" at/above 1048576 KB
# (1GiB), else "XM".

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/memory.sh"
}

@test "formats a size just under the 1GiB boundary as megabytes" {
  # (524288 + 512) / 1024 = 512.5 -> truncates to 512.
  run _mem_fmt 524288
  [ "$output" = "512M" ]
}

@test "formats a size exactly at the 1GiB boundary as gigabytes" {
  run _mem_fmt 1048576
  [ "$output" = "1.0G" ]
}

@test "formats a size above the 1GiB boundary as gigabytes" {
  run _mem_fmt 2097152
  [ "$output" = "2.0G" ]
}

@test "formats a small size as megabytes" {
  # (10240 + 512) / 1024 = 10.5 -> truncates to 10.
  run _mem_fmt 10240
  [ "$output" = "10M" ]
}

#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/clock.sh"
}

@test "_sleep_to_boundary sleeps no longer than the given interval" {
  local start end elapsed
  start="$(date +%s)"
  _sleep_to_boundary 1
  end="$(date +%s)"
  elapsed=$(( end - start ))
  [ "$elapsed" -le 1 ]
}

@test "_sleep_to_boundary falls back to plain sleep when perl is unavailable" {
  # Shadow `perl` with a PATH entry that only provides a failing perl shim,
  # so `_sleep_to_boundary` must take its `|| sleep` fallback.
  local shim_dir; shim_dir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${shim_dir}/perl"
  chmod +x "${shim_dir}/perl"
  local start end elapsed
  start="$(date +%s)"
  PATH="${shim_dir}:${PATH}" _sleep_to_boundary 1
  end="$(date +%s)"
  elapsed=$(( end - start ))
  rm -rf "$shim_dir"
  [ "$elapsed" -ge 1 ]
}

@test "_sleep_to_boundary defaults to a 1s sleep on a non-positive interval" {
  local start end elapsed
  start="$(date +%s)"
  _sleep_to_boundary 0
  end="$(date +%s)"
  elapsed=$(( end - start ))
  [ "$elapsed" -le 1 ]
}

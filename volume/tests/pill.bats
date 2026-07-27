#!/usr/bin/env bats
# Locks the item's `ridge add` call to include the pill
# corner-radius/height flags (matching the other widgets' pills). volume has
# no _pill_flags() helper - corner-radius/bg-height are each emitted via their
# own small helper instead, both omitted by default so the pill's radius/
# height auto-adapt to ridge's global defaults (TASK-139).

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/volume.sh"
}

@test "ridge add call includes the _corner_radius_flag and _bg_height_flag calls" {
  run grep -E '^\s*ridge add "\$ITEM_ID"' "${PLUGIN_DIR}/volume.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'$(_corner_radius_flag)'* ]]
  [[ "$output" == *'$(_bg_height_flag)'* ]]
  [[ "$output" == *'--icon-padding-right 8'* ]]
}

@test "_corner_radius_flag is empty by default (ridge global default)" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  run _corner_radius_flag
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "_corner_radius_flag honors an explicit corner_radius override" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"12"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  run _corner_radius_flag
  [ "$output" = "--bg-corner-radius 12" ]
}

@test "_bg_height_flag is empty by default (auto)" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  run _bg_height_flag
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "_bg_height_flag honors an explicit bg_height override" {
  local f; f="$(mktemp)"
  printf '%s' '{"bg_height":"30"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  run _bg_height_flag
  [ "$output" = "--bg-height 30" ]
}

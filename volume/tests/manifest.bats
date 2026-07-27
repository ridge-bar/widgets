#!/usr/bin/env bats
# Locks the manifest's declared ops to the ridge verbs the script emits, so
# enforcement can never silently break the shipped plugin.

setup() { PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."; }

@test "manifest declares every wire op the script emits" {
  # Wire ops the script uses: add/set/remove (ridge add|set|remove), and popup
  # (both `ridge popup toggle` and `ridge popup set-rows` map to the single
  # "popup" op - see Sources/RidgeCore/APIProtocol.swift's Op enum).
  for op in add set remove popup; do
    grep -E "ops:.*\b${op}\b" "${PLUGIN_DIR}/plugin.yaml" \
      || { echo "manifest missing op: ${op}"; false; }
  done
}

@test "script emits no ridge verb outside the declared set" {
  run bash -c "grep -ohE 'ridge (add|set|remove|move|refresh|query|subscribe|popup|bracket) ?' \
    '${PLUGIN_DIR}/volume.sh' | awk '{print \$2}' | sort -u"
  [ -n "$output" ] || { echo "no ridge verbs extracted - check the grep pattern"; false; }
  for verb in $output; do
    case "$verb" in
      add|set|remove|popup) : ;;
      *) echo "script uses undeclared verb: $verb"; false ;;
    esac
  done
}

@test "settings and settings_schema declare the same keys" {
  run bash -c "yq -o=json '.settings' '${PLUGIN_DIR}/plugin.yaml' 2>/dev/null | jq -r 'keys[]' | sort"
  if [ -z "$output" ]; then
    skip "yq not available"
  fi
  settings_keys="$output"
  run bash -c "yq -o=json '.settings_schema' '${PLUGIN_DIR}/plugin.yaml' 2>/dev/null | jq -r 'keys[]' | sort"
  schema_keys="$output"
  [ "$settings_keys" = "$schema_keys" ]
}

@test "plugin.yaml is valid YAML with owns=volume." {
  run bash -c "yq -o=json '.' '${PLUGIN_DIR}/plugin.yaml'"
  [ "$status" -eq 0 ]
  run bash -c "yq -r '.owns' '${PLUGIN_DIR}/plugin.yaml'"
  [ "$output" = "volume." ]
}

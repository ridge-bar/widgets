#!/usr/bin/env bats
# Locks the manifest's declared ops to the ridge verbs the script emits, so
# enforcement can never silently break the shipped plugin.

setup() { PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."; }

@test "manifest declares every wire op the script emits" {
  # Wire ops the script uses: add/set/remove (ridge add|set|remove).
  for op in add set remove; do
    grep -E "ops:.*\b${op}\b" "${PLUGIN_DIR}/plugin.yaml" \
      || { echo "manifest missing op: ${op}"; false; }
  done
}

@test "script emits no ridge verb outside the declared set" {
  run bash -c "grep -ohE 'ridge (add|set|remove|move|refresh|query|subscribe|popup|bracket) ?' \
    '${PLUGIN_DIR}/keyboard.sh' | awk '{print \$2}' | sort -u"
  [ -n "$output" ] || { echo "no ridge verbs extracted - check the grep pattern"; false; }
  for verb in $output; do
    case "$verb" in
      add|set|remove) : ;;
      *) echo "script uses undeclared verb: $verb"; false ;;
    esac
  done
}

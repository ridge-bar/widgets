#!/usr/bin/env bats
# Locks the manifest's declared ops to the ridge verbs the script emits, so
# enforcement can never silently break the shipped plugin.

setup() { PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."; }

@test "manifest declares every wire op the script emits" {
  # Wire ops the script uses: add/set/remove (ridge add|set|remove),
  # popup (ridge popup toggle|set-rows).
  for op in add set remove popup; do
    grep -E "ops:.*\b${op}\b" "${PLUGIN_DIR}/plugin.yaml" \
      || { echo "manifest missing op: ${op}"; false; }
  done
}

@test "script emits no ridge verb outside the declared set" {
  run bash -c "grep -ohE 'ridge (add|set|remove|move|refresh|query|subscribe|popup|bracket) ?' \
    '${PLUGIN_DIR}/weather.sh' | awk '{print \$2}' | sort -u"
  [ -n "$output" ] || { echo "no ridge verbs extracted - check the grep pattern"; false; }
  for verb in $output; do
    case "$verb" in
      add|set|remove|popup) : ;;
      *) echo "script uses undeclared verb: $verb"; false ;;
    esac
  done
}

@test "settings and settings_schema keys match exactly" {
  # Line-based parse (stdlib only, no PyYAML dependency): a section runs from
  # its "name:" line (column 0) to the next column-0 line; keys are indented
  # "  key:" lines within it.
  run python3 -c "
def section_keys(lines, name):
    keys, in_sec = [], False
    for line in lines:
        if line == name + ':':
            in_sec = True
            continue
        if in_sec:
            if line and not line[0].isspace():
                break
            stripped = line.strip()
            if stripped:
                keys.append(stripped.split(':')[0].strip())
    return set(keys)

lines = open('${PLUGIN_DIR}/plugin.yaml').read().splitlines()
settings_keys = section_keys(lines, 'settings')
schema_keys = section_keys(lines, 'settings_schema')
missing_schema = settings_keys - schema_keys
missing_settings = schema_keys - settings_keys
assert not missing_schema, f'settings without settings_schema entry: {sorted(missing_schema)}'
assert not missing_settings, f'settings_schema without settings entry: {sorted(missing_settings)}'
assert settings_keys, 'no settings keys found - check the parser'
"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

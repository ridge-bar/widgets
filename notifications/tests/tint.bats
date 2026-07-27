#!/usr/bin/env bats
# Exercises the tint state decision and the style-only `ridge set` flags -
# the ONLY fields the manifest's styles grant permits on the foreign target.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/notifications.sh"
}

@test "_notif_state tints on a positive count, normal on zero or error" {
  run _notif_state 3
  [ "$output" = "tint" ]
  run _notif_state 0
  [ "$output" = "normal" ]
  run _notif_state ""      # query error must never leave the clock stuck tinted
  [ "$output" = "normal" ]
}

@test "_style_flags uses the default tint/normal colors" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  run _style_flags tint
  [ "$output" = "--bg-color theme:warning --color #12161D" ]
  run _style_flags normal
  [ "$output" = "--bg-color theme:background --color theme:primary" ]
}

@test "_style_flags honors overridden colors" {
  local f; f="$(mktemp)"
  printf '%s' '{"tint_bg_color":"#111111","normal_label_color":"#222222"}' > "$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  run _style_flags tint
  [ "$output" = "--bg-color #111111 --color #12161D" ]
  run _style_flags normal
  [ "$output" = "--bg-color theme:background --color #222222" ]
}

@test "_style_flags emits only styles-grant fields (bg-color, color)" {
  RIDGE_PLUGIN_SETTINGS="" load_settings
  for state in tint normal; do
    run _style_flags "$state"
    for flag in $output; do
      case "$flag" in
        --bg-color|--color|\#*|theme:*) : ;;
        *) echo "non-style flag emitted: $flag"; false ;;
      esac
    done
  done
}

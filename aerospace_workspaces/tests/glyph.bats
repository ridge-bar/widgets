#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  # Sourcing must NOT start the event loop.
  source "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
}

@test "app_icon maps a known app to its sketchybar-app-font ligature" {
  run app_icon "Google Chrome"
  [ "$status" -eq 0 ]
  [ "$output" = ":google_chrome:" ]
}

@test "app_icon maps kitty" {
  run app_icon "kitty"
  [ "$status" -eq 0 ]
  [ "$output" = ":kitty:" ]
}

@test "app_icon falls back to :default: for an unmapped app" {
  run app_icon "TotallyUnknownApp 9000"
  [ "$status" -eq 0 ]
  [ "$output" = ":default:" ]
}

@test "app_icon resolves a prefix-pattern mapping" {
  run app_icon "Adobe Bridge 2024"
  [ "$status" -eq 0 ]
  [ "$output" = ":adobe_bridge:" ]
}

@test "sanitize replaces unsafe chars" {
  run sanitize "web:2 / dev"
  [ "$output" = "web_2___dev" ]
}

@test "_window_glyphs: one glyph per window (not deduped), focused flagged" {
  run _window_glyphs "1" "${BATS_TEST_DIRNAME}/fixtures/windows_wid.tsv" "101" "5"
  [ "$status" -eq 0 ]
  # three windows in ws 1 (two kitty, one Safari) - undeduped, window 101 focused
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "3" ]
  echo "$output" | sed -n '2p' | grep -q $'\t1$'   # 2nd window (id 101) is focused
  echo "$output" | sed -n '1p' | grep -q $'\t0$'
}

@test "_window_glyphs caps at max" {
  run _window_glyphs "1" "${BATS_TEST_DIRNAME}/fixtures/windows_wid.tsv" "" "2"
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "2" ]
}

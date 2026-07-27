#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  # Sourcing must NOT start the event loop.
  source "${PLUGIN_DIR}/aerospace-apps-plugin.sh"
}

@test "app_icon maps a known app to its app-icon ligature" {
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

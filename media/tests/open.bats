#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/media.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  RAW_APP="$(cat "${FIX}/get_raw_app.txt")"
  RAW_BROWSER="$(cat "${FIX}/get_raw_browser.txt")"
  RAW_EMPTY="$(cat "${FIX}/get_raw_empty.txt")"
}

@test "_media_open_bundle_id extracts the ClientBundleIdentifier" {
  run _media_open_bundle_id "$RAW_APP"
  [ "$output" = "com.spotify.client" ]
  run _media_open_bundle_id "$RAW_BROWSER"
  [ "$output" = "com.google.Chrome" ]
}

@test "_media_open_bundle_id is empty when the field is absent" {
  run _media_open_bundle_id "$RAW_EMPTY"
  [ -z "$output" ]
}

@test "_media_is_browser_bundle: a real app bundle is not a browser" {
  run _media_is_browser_bundle "com.spotify.client"
  [ "$status" -ne 0 ]
}

@test "_media_is_browser_bundle: known browser bundle ids match" {
  for bundle in com.google.Chrome com.apple.Safari org.mozilla.firefox com.microsoft.edgemac com.brave.Browser company.thebrowser.Browser; do
    run _media_is_browser_bundle "$bundle"
    [ "$status" -eq 0 ] || { echo "expected $bundle to be classified as a browser"; false; }
  done
}

@test "_media_is_browser_bundle: an empty bundle id counts as a browser (falls back to the web player)" {
  run _media_is_browser_bundle ""
  [ "$status" -eq 0 ]
}

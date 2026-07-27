#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/vpn.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  NETBIRD_CONNECTED="$(cat "${FIX}/netbird_connected.txt")"
  NETBIRD_DISCONNECTED="$(cat "${FIX}/netbird_disconnected.txt")"
  WARP_CONNECTED="$(cat "${FIX}/warp_connected.txt")"
  WARP_DISCONNECTED="$(cat "${FIX}/warp_disconnected.txt")"
  NETBIRD_GARBLED="$(cat "${FIX}/netbird_garbled.txt")"
  WARP_GARBLED="$(cat "${FIX}/warp_garbled.txt")"
  EMPTY="$(cat "${FIX}/empty.txt")"
}

@test "_vpn_classify_netbird reports connected from a Management: Connected line" {
  run _vpn_classify_netbird "$NETBIRD_CONNECTED"
  [ "$output" = "connected" ]
}

@test "_vpn_classify_netbird reports disconnected from a clean non-matching status" {
  run _vpn_classify_netbird "$NETBIRD_DISCONNECTED"
  [ "$output" = "disconnected" ]
}

@test "_vpn_classify_netbird reports unknown for garbled output" {
  run _vpn_classify_netbird "$NETBIRD_GARBLED"
  [ "$output" = "unknown" ]
}

@test "_vpn_classify_netbird reports unknown for empty output" {
  run _vpn_classify_netbird "$EMPTY"
  [ "$output" = "unknown" ]
}

@test "_vpn_classify_warp reports connected from an update: Connected line" {
  run _vpn_classify_warp "$WARP_CONNECTED"
  [ "$output" = "connected" ]
}

@test "_vpn_classify_warp reports disconnected from a clean non-matching status" {
  run _vpn_classify_warp "$WARP_DISCONNECTED"
  [ "$output" = "disconnected" ]
}

@test "_vpn_classify_warp reports unknown for garbled output" {
  run _vpn_classify_warp "$WARP_GARBLED"
  [ "$output" = "unknown" ]
}

@test "_vpn_classify_warp reports unknown for empty output" {
  run _vpn_classify_warp "$EMPTY"
  [ "$output" = "unknown" ]
}

@test "_vpn_toggle_label flips between Connect and Disconnect" {
  run _vpn_toggle_label "NetBird" "connected"
  [ "$output" = "NetBird: Disconnect" ]
  run _vpn_toggle_label "NetBird" "disconnected"
  [ "$output" = "NetBird: Connect" ]
  run _vpn_toggle_label "Cloudflare WARP" "unknown"
  [ "$output" = "Cloudflare WARP: Connect" ]
}

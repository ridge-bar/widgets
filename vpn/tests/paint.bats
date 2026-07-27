#!/usr/bin/env bats
# Exercises the combined bar-item paint-state and popup-header selection
# functions across every (netbird_state, warp_state) combination.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/vpn.sh"
  CONNECTED="#9ECE6A"
  WARP_ACCENT="#FF9E64"
  NETBIRD_ICON="#1F2335"
  OFF="#565F89"
  UNKNOWN="#E0AF68"
  BG="#292E42"
}

@test "_vpn_paint_state: both connected paints green bg with the WARP orange icon accent" {
  run _vpn_paint_state connected connected "$CONNECTED" "$WARP_ACCENT" "$NETBIRD_ICON" "$OFF" "$UNKNOWN" "$BG"
  [ "$output" = "${CONNECTED}|${WARP_ACCENT}|${VPN_GLYPH_CONNECTED}" ]
}

@test "_vpn_paint_state: NetBird-only connected paints green bg with the dark NetBird icon" {
  run _vpn_paint_state connected disconnected "$CONNECTED" "$WARP_ACCENT" "$NETBIRD_ICON" "$OFF" "$UNKNOWN" "$BG"
  [ "$output" = "${CONNECTED}|${NETBIRD_ICON}|${VPN_GLYPH_CONNECTED}" ]
}

@test "_vpn_paint_state: WARP-only connected paints green bg with the orange icon accent" {
  run _vpn_paint_state disconnected connected "$CONNECTED" "$WARP_ACCENT" "$NETBIRD_ICON" "$OFF" "$UNKNOWN" "$BG"
  [ "$output" = "${CONNECTED}|${WARP_ACCENT}|${VPN_GLYPH_CONNECTED}" ]
}

@test "_vpn_paint_state: both disconnected paints the standard pill bg with a greyed-out glyph" {
  run _vpn_paint_state disconnected disconnected "$CONNECTED" "$WARP_ACCENT" "$NETBIRD_ICON" "$OFF" "$UNKNOWN" "$BG"
  [ "$output" = "${BG}|${OFF}|${VPN_GLYPH_OFF}" ]
}

@test "_vpn_paint_state: one unknown and the other disconnected paints unknown_color bg with a visible dark glyph" {
  run _vpn_paint_state unknown disconnected "$CONNECTED" "$WARP_ACCENT" "$NETBIRD_ICON" "$OFF" "$UNKNOWN" "$BG"
  [ "$output" = "${UNKNOWN}|${NETBIRD_ICON}|${VPN_GLYPH_OFF}" ]
  run _vpn_paint_state disconnected unknown "$CONNECTED" "$WARP_ACCENT" "$NETBIRD_ICON" "$OFF" "$UNKNOWN" "$BG"
  [ "$output" = "${UNKNOWN}|${NETBIRD_ICON}|${VPN_GLYPH_OFF}" ]
}

@test "_vpn_paint_state: a definite connection wins over the other backend being unknown" {
  run _vpn_paint_state connected unknown "$CONNECTED" "$WARP_ACCENT" "$NETBIRD_ICON" "$OFF" "$UNKNOWN" "$BG"
  [ "$output" = "${CONNECTED}|${NETBIRD_ICON}|${VPN_GLYPH_CONNECTED}" ]
}

@test "_vpn_header_fields: both connected shows the combined label with the cyan accent" {
  run _vpn_header_fields connected connected "$CONNECTED" "$OFF"
  [ "$output" = "NetBird + WARP|${VPN_GLYPH_CONNECTED}|${VPN_WARP_HEADER_COLOR}" ]
}

@test "_vpn_header_fields: NetBird-only connected shows the green accent" {
  run _vpn_header_fields connected disconnected "$CONNECTED" "$OFF"
  [ "$output" = "NetBird: Connected|${VPN_GLYPH_CONNECTED}|${CONNECTED}" ]
}

@test "_vpn_header_fields: WARP-only connected shows the cyan accent" {
  run _vpn_header_fields disconnected connected "$CONNECTED" "$OFF"
  [ "$output" = "Cloudflare WARP: Connected|${VPN_GLYPH_CONNECTED}|${VPN_WARP_HEADER_COLOR}" ]
}

@test "_vpn_header_fields: disconnected shows the off accent" {
  run _vpn_header_fields disconnected disconnected "$CONNECTED" "$OFF"
  [ "$output" = "Disconnected|${VPN_GLYPH_OFF}|${OFF}" ]
}

@test "_vpn_header_fields: unknown backends read as not-connected" {
  run _vpn_header_fields unknown unknown "$CONNECTED" "$OFF"
  [ "$output" = "Disconnected|${VPN_GLYPH_OFF}|${OFF}" ]
}

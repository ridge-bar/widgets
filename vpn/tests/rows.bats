#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/vpn.sh"
}

@test "_vpn_popup_rows_json always includes the status header row first" {
  run _vpn_popup_rows_json "Disconnected" "$VPN_GLYPH_OFF" "#565F89" \
    false "" "" \
    false "" "" \
    false ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].text == "Disconnected"'
  echo "$output" | jq -e '.[0].type == "header" and .[0].color == "#565F89"'
}

@test "_vpn_popup_rows_json includes the NetBird row only when present" {
  run _vpn_popup_rows_json "Disconnected" "$VPN_GLYPH_OFF" "#565F89" \
    true "NetBird: Connect" "VPN_ACTION=netbird-toggle '/path/vpn.sh'" \
    false "" "" \
    false ""
  echo "$output" | jq -e 'length == 2'
  echo "$output" | jq -e '.[1].text == "NetBird: Connect"'
  echo "$output" | jq -e '.[1].click | contains("VPN_ACTION=netbird-toggle")'
}

@test "_vpn_popup_rows_json includes the WARP row only when present" {
  run _vpn_popup_rows_json "Disconnected" "$VPN_GLYPH_OFF" "#565F89" \
    false "" "" \
    true "Cloudflare WARP: Connect" "VPN_ACTION=warp-toggle '/path/vpn.sh'" \
    false ""
  echo "$output" | jq -e 'length == 2'
  echo "$output" | jq -e '.[1].text == "Cloudflare WARP: Connect"'
}

@test "_vpn_popup_rows_json includes the re-auth row only when visible" {
  run _vpn_popup_rows_json "Cloudflare WARP: Connected" "$VPN_GLYPH_CONNECTED" "$VPN_WARP_HEADER_COLOR" \
    false "" "" \
    true "Cloudflare WARP: Disconnect" "VPN_ACTION=warp-toggle '/path/vpn.sh'" \
    true "VPN_ACTION=warp-reauth '/path/vpn.sh'"
  echo "$output" | jq -e 'length == 3'
  echo "$output" | jq -e '.[2].text == "Re-auth WARP"'
  echo "$output" | jq -e '.[2].click | contains("VPN_ACTION=warp-reauth")'
}

@test "_vpn_popup_rows_json separates the NetBird and WARP sections when both are present" {
  run _vpn_popup_rows_json "Cloudflare WARP: Connected" "$VPN_GLYPH_CONNECTED" "$VPN_WARP_HEADER_COLOR" \
    true "NetBird: Connect" "VPN_ACTION=netbird-toggle '/path/vpn.sh'" \
    true "Cloudflare WARP: Disconnect" "VPN_ACTION=warp-toggle '/path/vpn.sh'" \
    true "VPN_ACTION=warp-reauth '/path/vpn.sh'"
  [ "$status" -eq 0 ]
  # header, NetBird toggle, separator, WARP toggle, re-auth
  echo "$output" | jq -e 'length == 5'
  echo "$output" | jq -e '.[2].type == "separator"'
  echo "$output" | jq -e '[.[] | select(.type != "separator") | .text] == ["Cloudflare WARP: Connected","NetBird: Connect","Cloudflare WARP: Disconnect","Re-auth WARP"]'
}

@test "_vpn_popup_rows_json omits the section separator when only one backend is present" {
  run _vpn_popup_rows_json "Disconnected" "$VPN_GLYPH_OFF" "#565F89" \
    true "NetBird: Connect" "VPN_ACTION=netbird-toggle '/path/vpn.sh'" \
    false "" "" \
    false ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | select(.type == "separator")] | length == 0'
}

@test "_vpn_popup_rows_json safely escapes JSON-breaking characters in a label" {
  run _vpn_popup_rows_json 'Disconnected" ; rm -rf /' "$VPN_GLYPH_OFF" "#565F89" \
    false "" "" \
    false "" "" \
    false ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].text | contains("rm -rf")'
}

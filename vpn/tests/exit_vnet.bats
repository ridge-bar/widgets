#!/usr/bin/env bats
# Exercises the NetBird exit-node / WARP vnet parsing and row-building - the
# port of the sketchybar source's exit-node and virtual-network row dispatch.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/vpn.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  NETWORKS_LIST="$(cat "${FIX}/netbird_networks_list.txt")"
  NETWORKS_EMPTY="$(cat "${FIX}/netbird_networks_list_empty.txt")"
  NETWORKS_ERROR="$(cat "${FIX}/netbird_networks_list_error.txt")"
  VNET_JSON="$(cat "${FIX}/warp_vnet.json")"
  VNET_GARBLED="$(cat "${FIX}/warp_vnet_garbled.txt")"
  EMPTY="$(cat "${FIX}/empty.txt")"
}

# --- _vpn_parse_netbird_exit_nodes ------------------------------------------

@test "_vpn_parse_netbird_exit_nodes extracts only the 0.0.0.0/0 routes" {
  run _vpn_parse_netbird_exit_nodes "$NETWORKS_LIST"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 2'
  echo "$output" | jq -e '.[0].id == "Exit Node (Server EU)" and .[0].selected == true'
  echo "$output" | jq -e '.[1].id == "Exit Node (Server US)" and .[1].selected == false'
}

@test "_vpn_parse_netbird_exit_nodes excludes non-exit network and domain routes" {
  run _vpn_parse_netbird_exit_nodes "$NETWORKS_LIST"
  echo "$output" | jq -e '[.[].id] | index("office-lan") == null'
  echo "$output" | jq -e '[.[].id] | index("internal-services") == null'
}

@test "_vpn_parse_netbird_exit_nodes returns an empty array for 'No networks available.'" {
  run _vpn_parse_netbird_exit_nodes "$NETWORKS_EMPTY"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_vpn_parse_netbird_exit_nodes returns an empty array for an error blob" {
  run _vpn_parse_netbird_exit_nodes "$NETWORKS_ERROR"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_vpn_parse_netbird_exit_nodes returns an empty array for empty input" {
  run _vpn_parse_netbird_exit_nodes "$EMPTY"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_vpn_parse_netbird_exit_nodes caps results at VPN_MAX_EXIT_NODES" {
  local many i block=""
  for i in $(seq 1 8); do
    block+="  - ID: Exit Node (Server $i)
    Network: 0.0.0.0/0
    Status: Not Selected

"
  done
  run _vpn_parse_netbird_exit_nodes "$block"
  echo "$output" | jq -e --argjson cap "$VPN_MAX_EXIT_NODES" 'length == $cap'
}

# --- _vpn_exit_node_label ----------------------------------------------------

@test "_vpn_exit_node_label strips the 'Exit Node (...)' wrapper" {
  run _vpn_exit_node_label "Exit Node (Server EU)"
  [ "$output" = "Server EU" ]
}

@test "_vpn_exit_node_label falls back to the raw id when it doesn't match" {
  run _vpn_exit_node_label "some-other-route-id"
  [ "$output" = "some-other-route-id" ]
}

# --- _vpn_parse_warp_vnets ---------------------------------------------------

@test "_vpn_parse_warp_vnets extracts id/name/selected from warp-cli -j vnet output" {
  run _vpn_parse_warp_vnets "$VNET_JSON"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 3'
  echo "$output" | jq -e '.[0].name == "Default" and .[0].selected == false'
  echo "$output" | jq -e '.[1].name == "Production" and .[1].selected == true'
  echo "$output" | jq -e '.[2].name == "Staging&Dev" and .[2].selected == false'
}

@test "_vpn_parse_warp_vnets returns an empty array for non-JSON error text" {
  run _vpn_parse_warp_vnets "$VNET_GARBLED"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_vpn_parse_warp_vnets returns an empty array for empty input" {
  run _vpn_parse_warp_vnets "$EMPTY"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_vpn_parse_warp_vnets caps results at VPN_MAX_VNETS" {
  local vnets="[]" i
  for i in $(seq 1 6); do
    vnets="$(jq -c --arg id "vnet-$i" --arg name "Net $i" '. + [{id: $id, name: $name, description: "", default: false}]' <<<"$vnets")"
  done
  local doc; doc="$(jq -n --argjson vnets "$vnets" '{active_vnet_id: "", virtual_networks: $vnets}')"
  run _vpn_parse_warp_vnets "$doc"
  echo "$output" | jq -e --argjson cap "$VPN_MAX_VNETS" 'length == $cap'
}

# --- _vpn_exit_node_rows_json ------------------------------------------------

@test "_vpn_exit_node_rows_json builds a hollow row with a select click for an unselected node" {
  local nodes='[{"id":"Exit Node (Server US)","selected":false}]'
  run _vpn_exit_node_rows_json "$nodes" "/path/vpn.sh" ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].text == "○ Server US"'
  echo "$output" | jq -e '.[0].click | contains("VPN_ACTION=netbird-exit-select")'
}

@test "_vpn_exit_node_rows_json builds a filled row with a deselect click for a selected node" {
  local nodes='[{"id":"Exit Node (Server EU)","selected":true}]'
  run _vpn_exit_node_rows_json "$nodes" "/path/vpn.sh" ""
  echo "$output" | jq -e '.[0].text == "● Server EU"'
  echo "$output" | jq -e '.[0].click | contains("VPN_ACTION=netbird-exit-deselect")'
}

@test "_vpn_exit_node_rows_json safely quotes a hostile id for the click command" {
  local hostile_id="Exit Node (Server EU)'; rm -rf /"
  local nodes; nodes="$(jq -cn --arg id "$hostile_id" '[{id: $id, selected: false}]')"
  run _vpn_exit_node_rows_json "$nodes" "/path/vpn.sh" ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].click | contains("VPN_EXIT_ID=")'
  # The hostile id must be shq-quoted (single-quoted, embedded quote escaped
  # as '\''), never bare in the click string - the two-shell-layer safety net.
  local click; click="$(jq -r '.[0].click' <<<"$output")"
  [[ "$click" == *"'\\''"* ]]
}

@test "_vpn_exit_node_rows_json returns an empty array for no nodes" {
  run _vpn_exit_node_rows_json "[]" "/path/vpn.sh" ""
  [ "$output" = "[]" ]
}

# --- _vpn_vnet_rows_json ------------------------------------------------------

@test "_vpn_vnet_rows_json builds a hollow row with a select click for an unselected vnet" {
  local vnets='[{"id":"vnet-1","name":"Production","selected":false}]'
  run _vpn_vnet_rows_json "$vnets" "/path/vpn.sh" ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].text == "○ Production"'
  echo "$output" | jq -e '.[0].click | contains("VPN_ACTION=warp-vnet-select")'
  echo "$output" | jq -e '.[0].click | contains("VPN_VNET_ID=")'
}

@test "_vpn_vnet_rows_json marks the currently selected vnet with a filled marker" {
  local vnets='[{"id":"vnet-1","name":"Production","selected":true}]'
  run _vpn_vnet_rows_json "$vnets" "/path/vpn.sh" ""
  echo "$output" | jq -e '.[0].text == "● Production"'
}

@test "_vpn_vnet_rows_json returns an empty array for no vnets" {
  run _vpn_vnet_rows_json "[]" "/path/vpn.sh" ""
  [ "$output" = "[]" ]
}

# --- _vpn_popup_rows_json: exit-node / vnet sections -------------------------

@test "_vpn_popup_rows_json omits the Exit Nodes/Virtual Networks headers when empty" {
  run _vpn_popup_rows_json "Disconnected" "$VPN_GLYPH_OFF" "#565F89" \
    false "" "" \
    false "" "" \
    false ""
  echo "$output" | jq -e '[.[].text] | index("Exit Nodes") == null'
  echo "$output" | jq -e '[.[].text] | index("Virtual Networks") == null'
}

@test "_vpn_popup_rows_json splices in an Exit Nodes section header and rows" {
  local exit_rows='[{"text":"● Server EU","click":"VPN_ACTION=netbird-exit-deselect VPN_EXIT_ID=x /path/vpn.sh"}]'
  run _vpn_popup_rows_json "NetBird: Connected" "$VPN_GLYPH_CONNECTED" "#9ECE6A" \
    true "NetBird: Disconnect" "VPN_ACTION=netbird-toggle '/path/vpn.sh'" \
    false "" "" \
    false "" \
    "$exit_rows" "[]"
  echo "$output" | jq -e 'length == 4'
  echo "$output" | jq -e '.[2].type == "header" and .[2].text == "Exit Nodes"'
  echo "$output" | jq -e '.[2].color == null'
  echo "$output" | jq -e '.[3].text == "● Server EU"'
}

@test "_vpn_popup_rows_json splices in a Virtual Networks section header and rows" {
  local vnet_rows='[{"text":"○ Production","click":"VPN_ACTION=warp-vnet-select VPN_VNET_ID=x /path/vpn.sh"}]'
  run _vpn_popup_rows_json "Disconnected" "$VPN_GLYPH_OFF" "#565F89" \
    false "" "" \
    true "Cloudflare WARP: Connect" "VPN_ACTION=warp-toggle '/path/vpn.sh'" \
    false "" \
    "[]" "$vnet_rows"
  echo "$output" | jq -e 'length == 4'
  echo "$output" | jq -e '.[2].type == "header" and .[2].text == "Virtual Networks"'
  echo "$output" | jq -e '.[2].color == null'
  echo "$output" | jq -e '.[3].text == "○ Production"'
}

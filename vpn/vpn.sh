#!/usr/bin/env bash
# Ridge vpn plugin: a connection-status glyph for NetBird + Cloudflare WARP,
# plus a popup with connect/disconnect toggles, NetBird exit-node selection,
# WARP virtual-network selection, and a WARP re-auth action. Ported from
# sketchybar's items/vpn.sh + plugins/vpn*.sh; the click-time spinner glyph
# animation is not ported (see README.md's "Deferred" section). Talks to
# ridge over $RIDGE_SOCKET via the `ridge` CLI.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEM_ID="vpn.status"

VPN_GLYPH_CONNECTED="󰦝"
VPN_GLYPH_OFF="󰦞"

# Row caps: matches the sketchybar source's MAX_EXIT/MAX_VNET - keeps the
# popup bounded regardless of how many networks an org has configured.
VPN_MAX_EXIT_NODES=5
VPN_MAX_VNETS=4

# Tokyo Night cyan (sketchybar source's VPNWARP/TN_CYAN) for the popup status
# header when WARP is the (or a) connected backend. Not user-configurable -
# a fixed accent, same idea as battery.sh's BATTERY_TITLE_COLOR.
VPN_WARP_HEADER_COLOR="#7DCFFF"

_have() { command -v "$1" >/dev/null 2>&1; }

# `timeout` isn't shipped on macOS by default; alarm+exec is the standard
# shim (matches the sibling media/tasks plugins). Wraps every
# `netbird status`/`warp-cli status` probe so a hung CLI can never stall the
# poll loop.
_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# Single-quote a string safely for POSIX /bin/sh. Ridge core executes stored
# click strings via `/bin/sh -c`, a second shell layer beyond this script's
# own eval; the click's env assignment, script path, and settings path must
# survive both.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Builds a self-reinvoke click command: re-exec this script with the given
# env var assignment set (plus RIDGE_PLUGIN_SETTINGS forwarded via shq), so a
# row click runs the action and repaints without waiting for the next poll.
build_reexec_cmd() {
  local env_assignment="$1" script_path="$2" settings_path="${3:-}"
  local out="$env_assignment"
  if [[ -n "$settings_path" ]]; then
    out="RIDGE_PLUGIN_SETTINGS=$(shq "$settings_path") ${out}"
  fi
  printf '%s %s' "$out" "$(shq "$script_path")"
}

# shellcheck disable=SC2034 # SETTING_* are consumed by main()/paint helpers, not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"

  # Icon font: VPN_GLYPH_OFF/VPN_GLYPH_CONNECTED are Nerd Font glyphs, so
  # they render as tofu in the system default font unless a Nerd Font
  # family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"

  # Poll interval in seconds. Must be a positive number, else default 3 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "3"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="3"

  # netbird_bin defaults to a `command -v` probe (matches the sketchybar
  # source, which runs with a minimal PATH), falling back to the standard
  # Homebrew path. plugin.yaml leaves the default empty since YAML can't
  # express a runtime probe as a literal string - same technique as tasks.sh's
  # HOME-expanded noteplan_dir/obsidian_inbox_dir defaults. The candidate is
  # not existence-checked here; presence is checked at each call site via
  # `[[ -x ... ]]` so a binary installed/removed after startup only requires
  # a poll tick's -x test, not a settings reload.
  SETTING_netbird_bin="$(jq -r '.netbird_bin // ""' <<<"$json")"
  [[ -n "$SETTING_netbird_bin" ]] || SETTING_netbird_bin="$(command -v netbird 2>/dev/null || printf '/opt/homebrew/bin/netbird')"

  SETTING_warp_bin="$(jq -r '.warp_bin // "/usr/local/bin/warp-cli"' <<<"$json")"

  SETTING_status_timeout_seconds="$(jq -r '.status_timeout_seconds // "5"' <<<"$json")"
  [[ "$SETTING_status_timeout_seconds" =~ ^[0-9]+$ && "$SETTING_status_timeout_seconds" -ge 1 && "$SETTING_status_timeout_seconds" -le 30 ]] || SETTING_status_timeout_seconds="5"

  SETTING_bg_color="$(jq -r '.bg_color // "theme:background"' <<<"$json")"
  SETTING_connected_color="$(jq -r '.connected_color // "theme:success"' <<<"$json")"
  SETTING_warp_accent_color="$(jq -r '.warp_accent_color // "theme:warning"' <<<"$json")"
  SETTING_netbird_icon_color="$(jq -r '.netbird_icon_color // "#12161D"' <<<"$json")"
  SETTING_off_color="$(jq -r '.off_color // "theme:secondary"' <<<"$json")"
  SETTING_unknown_color="$(jq -r '.unknown_color // "theme:warning"' <<<"$json")"

  SETTING_corner_radius="$(jq -r '.corner_radius // ""' <<<"$json")"
  if [[ -n "$SETTING_corner_radius" ]] && ! [[ "$SETTING_corner_radius" =~ ^[0-9]+$ && "$SETTING_corner_radius" -ge 0 && "$SETTING_corner_radius" -le 30 ]]; then
    SETTING_corner_radius=""
  fi
  # Empty (unset) means auto: ridge core adapts the pill height to the bar
  # height. bg_height stays a valid opt-in override; out-of-range or
  # non-numeric input resets to empty/auto rather than any fixed default.
  SETTING_bg_height="$(jq -r '.bg_height // ""' <<<"$json")"
  if [[ -n "$SETTING_bg_height" ]] && ! [[ "$SETTING_bg_height" =~ ^[0-9]+$ && "$SETTING_bg_height" -ge 16 && "$SETTING_bg_height" -le 48 ]]; then
    SETTING_bg_height=""
  fi
}

##############################################################################
# Pure functions: no I/O, no `netbird`/`warp-cli` calls - callers pass
# explicit values so these are directly testable against fixtures (see
# tests/classify.bats, tests/paint.bats, tests/rows.bats).
##############################################################################

# connected | disconnected | unknown, from a raw `netbird status`/`warp-cli
# status` text blob. Empty output (including a timed-out probe, which prints
# nothing) is "unknown", not "disconnected" - a clean non-matching status
# line legitimately means disconnected, but no output at all means the probe
# never produced a readable status. Output that contains neither the
# connected phrase nor even the backend's own status marker is treated the
# same way: it doesn't look like real status text, so it can't be trusted to
# mean "disconnected".
_vpn_classify_status() {
  local raw="$1" connected_pattern="$2" marker_pattern="$3"
  if [[ -z "$raw" ]]; then
    printf 'unknown'
    return
  fi
  if printf '%s' "$raw" | grep -q "$connected_pattern"; then
    printf 'connected'
    return
  fi
  if printf '%s' "$raw" | grep -q "$marker_pattern"; then
    printf 'disconnected'
    return
  fi
  printf 'unknown'
}

_vpn_classify_netbird() { _vpn_classify_status "$1" 'Management: Connected' 'Management:'; }
_vpn_classify_warp() { _vpn_classify_status "$1" 'update: Connected' 'update:'; }

# "NetBird: Connect"/"NetBird: Disconnect" (label flips with state). Applies
# to any backend name; "unknown" is treated as not-connected so the row
# offers the safe default action (attempt to connect).
_vpn_toggle_label() {
  local name="$1" state="$2"
  if [[ "$state" == "connected" ]]; then
    printf '%s: Disconnect' "$name"
  else
    printf '%s: Connect' "$name"
  fi
}

# bg_color|icon_color|glyph for the bar item. Both backends paint the same
# system-family connected bg; icon color distinguishes them (secondary accent
# when WARP is part of the connected set, ink-toned when NetBird-only).
# Any backend "unknown"
# (with neither actually connected) paints unknown_color instead of folding
# into "disconnected" - a parse failure must read differently from a clean
# off state. Ported paint logic from the sketchybar source's vpn.sh, plus the
# unknown branch which is a v1 addition.
_vpn_paint_state() {
  local nb="$1" warp="$2" connected_color="$3" warp_accent="$4" netbird_icon_color="$5" off_color="$6" unknown_color="$7" bg_color="$8"
  if [[ "$nb" == "connected" || "$warp" == "connected" ]]; then
    local icon_color
    if [[ "$warp" == "connected" ]]; then icon_color="$warp_accent"; else icon_color="$netbird_icon_color"; fi
    printf '%s|%s|%s' "$connected_color" "$icon_color" "$VPN_GLYPH_CONNECTED"
    return
  fi
  # Unknown keeps the warning-hued bg with the ink-toned glyph; painting
  # the glyph with the bg color makes it invisible (an empty-looking pill).
  if [[ "$nb" == "unknown" || "$warp" == "unknown" ]]; then
    printf '%s|%s|%s' "$unknown_color" "$netbird_icon_color" "$VPN_GLYPH_OFF"
    return
  fi
  # Disconnected reads as idle: the standard pill bg every other widget uses,
  # with the glyph greyed out - not an off_color-filled pill, which stood out
  # against the rest of the bar.
  printf '%s|%s|%s' "$bg_color" "$off_color" "$VPN_GLYPH_OFF"
}

# label|glyph|color for the popup's status header row. Unlike the bar item's
# single connected bg, the header uses the WARP header accent whenever WARP
# is (or is among) the connected backend(s), and the connected color only for
# a NetBird-only connection - matches the sketchybar source's status_color
# selection in vpn_popup.sh. "unknown" reads as not-connected here: the
# reduced v1 header only distinguishes the four states the popup shows
# (both / NetBird-only / WARP-only / disconnected), not a parse-failure state.
_vpn_header_fields() {
  local nb_state="$1" warp_state="$2" connected_color="$3" off_color="$4"
  local nb_connected=false warp_connected=false
  [[ "$nb_state" == "connected" ]] && nb_connected=true
  [[ "$warp_state" == "connected" ]] && warp_connected=true

  if [[ "$nb_connected" == "true" && "$warp_connected" == "true" ]]; then
    printf 'NetBird + WARP|%s|%s' "$VPN_GLYPH_CONNECTED" "$VPN_WARP_HEADER_COLOR"
  elif [[ "$nb_connected" == "true" ]]; then
    printf 'NetBird: Connected|%s|%s' "$VPN_GLYPH_CONNECTED" "$connected_color"
  elif [[ "$warp_connected" == "true" ]]; then
    printf 'Cloudflare WARP: Connected|%s|%s' "$VPN_GLYPH_CONNECTED" "$VPN_WARP_HEADER_COLOR"
  else
    printf 'Disconnected|%s|%s' "$VPN_GLYPH_OFF" "$off_color"
  fi
}

# Builds the popup rows via `jq -n --arg` (not string splicing), so status
# text can never break the JSON payload. The NetBird/WARP toggle rows are
# omitted entirely (not shown disabled) when their binary isn't resolvable -
# ridge's PopupRow has no "disabled" field, and an unusable action is
# clearer left off the menu than shown inert. Re-auth is a fourth row, shown
# only while WARP is connected. exit_rows_json/vnet_rows_json (pre-built by
# _vpn_exit_node_rows_json/_vpn_vnet_rows_json) are spliced in as their own
# {type: "header", text: "..."} section - text only, no icon/color, so the
# label stays flush-left like every other section - immediately after the
# NetBird/WARP toggle they extend, and omitted entirely when empty.
_vpn_popup_rows_json() {
  local header_label="$1" header_glyph="$2" header_color="$3" \
    netbird_present="$4" netbird_label="$5" netbird_click="$6" \
    warp_present="$7" warp_label="$8" warp_click="$9" \
    reauth_visible="${10}" reauth_click="${11}" \
    exit_rows_json="${12:-[]}" vnet_rows_json="${13:-[]}"

  jq -n \
    --arg header_label "$header_label" \
    --arg header_glyph "$header_glyph" \
    --arg header_color "$header_color" \
    --argjson netbird_present "$netbird_present" \
    --arg netbird_label "$netbird_label" \
    --arg netbird_click "$netbird_click" \
    --argjson warp_present "$warp_present" \
    --arg warp_label "$warp_label" \
    --arg warp_click "$warp_click" \
    --argjson reauth_visible "$reauth_visible" \
    --arg reauth_click "$reauth_click" \
    --argjson exit_rows "$exit_rows_json" \
    --argjson vnet_rows "$vnet_rows_json" \
    '
    ((if $netbird_present then [{text: $netbird_label, click: $netbird_click}] else [] end)
     + (if ($exit_rows | length) > 0 then [{type: "header", text: "Exit Nodes"}] + $exit_rows else [] end)) as $nb
    | ((if $warp_present then [{text: $warp_label, click: $warp_click}] else [] end)
       + (if ($vnet_rows | length) > 0 then [{type: "header", text: "Virtual Networks"}] + $vnet_rows else [] end)) as $warp
    | [{type: "header", text: $header_label, color: $header_color}]
      + $nb
      + (if (($nb | length) > 0 and ($warp | length) > 0) then [{type: "separator"}] else [] end)
      + $warp
      + (if $reauth_visible then [{text: "Re-auth WARP", click: $reauth_click}] else [] end)
    '
}

# id|network|selected rows from `netbird networks list`'s free-text output,
# filtered to exit nodes (a full-tunnel default route: Network 0.0.0.0/0) and
# capped at VPN_MAX_EXIT_NODES. No JSON/YAML output mode exists for this
# command (verified against the netbird CLI source) - the awk state machine
# below is defensive against version drift: it keys off the "- ID:"/
# "Network:"/"Status:" line prefixes the source always prints and ignores any
# other field (Domains:, Resolved IPs:, blank lines), so it degrades to an
# empty result rather than emitting broken JSON on a format change. `-R -s`
# (raw input, slurp) means jq never throws a top-level parse error, even on
# empty or garbled input.
_vpn_parse_netbird_exit_nodes() {
  local raw="$1" tsv
  tsv="$(awk '
    /^[[:space:]]*- ID:/ {
      if (id != "") print id "\t" network "\t" status
      id=$0; sub(/^[[:space:]]*- ID:[[:space:]]*/, "", id)
      network=""; status=""
    }
    /^[[:space:]]*Network:/ {
      network=$0; sub(/^[[:space:]]*Network:[[:space:]]*/, "", network)
    }
    /^[[:space:]]*Status:/ {
      status=$0; sub(/^[[:space:]]*Status:[[:space:]]*/, "", status)
    }
    END { if (id != "") print id "\t" network "\t" status }
  ' <<<"$raw")"

  jq -R -s -c --argjson cap "$VPN_MAX_EXIT_NODES" '
    split("\n") | map(select(length > 0)) | map(split("\t"))
    | map({id: (.[0] // ""), network: (.[1] // ""), selected: ((.[2] // "") == "Selected")})
    | map(select(.network == "0.0.0.0/0"))
    | .[0:$cap]
    | map({id, selected})
  ' <<<"$tsv" 2>/dev/null || printf '[]'
}

# "Server EU" from "Exit Node (Server EU)" - the sketchybar source's admin-
# configured naming convention for exit-node routes. Falls back to the raw id
# unchanged when it doesn't match (a route not named that way, or a future
# naming scheme), so an unexpected id still gets a usable row label instead of
# an empty one.
_vpn_exit_node_label() {
  local id="$1"
  if [[ "$id" =~ ^Exit\ Node\ \((.*)\)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$id"
  fi
}

# id|name|selected rows from `warp-cli -j vnet`'s JSON output (a genuine
# structured mode, unlike netbird networks list), capped at VPN_MAX_VNETS.
# `-R -s` plus `try fromjson catch {}` means a disconnected daemon's
# non-JSON error text (or empty output) degrades to an empty array instead of
# a jq parse failure.
_vpn_parse_warp_vnets() {
  local raw="$1"
  jq -R -s -c --argjson cap "$VPN_MAX_VNETS" '
    (try fromjson catch {}) as $d
    | ($d.active_vnet_id // "") as $active
    | ($d.virtual_networks // [])
    | map({id: (.id // ""), name: (.name // .id // ""), selected: (.id == $active)})
    | .[0:$cap]
  ' <<<"$raw" 2>/dev/null || printf '[]'
}

# Builds {text, click} popup rows for each parsed exit node. Marker mirrors
# the sketchybar source's filled/hollow bullet (selected vs not); the click
# toggles select/deselect per row so a currently-selected node can be turned
# off directly, not just replaced by picking another. Text goes through
# `jq -n --arg` (via the row-building jq call), never string interpolation,
# so a hostile route id can't break the JSON payload; the id going into the
# click command goes through `shq` for the same reason at the shell layer.
_vpn_exit_node_rows_json() {
  local nodes_json="$1" script_path="$2" settings_path="$3"
  local out='[]' entry id selected marker action click row
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id="$(jq -r '.id' <<<"$entry")"
    selected="$(jq -r '.selected' <<<"$entry")"
    if [[ "$selected" == "true" ]]; then marker="●"; action="netbird-exit-deselect"; else marker="○"; action="netbird-exit-select"; fi
    click="$(build_reexec_cmd "VPN_ACTION=${action} VPN_EXIT_ID=$(shq "$id")" "$script_path" "$settings_path")"
    row="$(jq -n --arg text "${marker} $(_vpn_exit_node_label "$id")" --arg click "$click" '{text: $text, click: $click}')"
    out="$(jq -c --argjson row "$row" '. + [$row]' <<<"$out")"
  done < <(jq -c '.[]' <<<"$nodes_json" 2>/dev/null)
  printf '%s' "$out"
}

# Builds {text, click} popup rows for each parsed WARP vnet - same
# marker/click-toggle shape as exit nodes, but selecting a vnet always means
# "switch to it" (WARP has no bare vnet-deselect concept; the row for
# "Default" plays that role).
_vpn_vnet_rows_json() {
  local vnets_json="$1" script_path="$2" settings_path="$3"
  local out='[]' entry id name selected marker click row
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    id="$(jq -r '.id' <<<"$entry")"
    name="$(jq -r '.name' <<<"$entry")"
    selected="$(jq -r '.selected' <<<"$entry")"
    if [[ "$selected" == "true" ]]; then marker="●"; else marker="○"; fi
    click="$(build_reexec_cmd "VPN_ACTION=warp-vnet-select VPN_VNET_ID=$(shq "$id")" "$script_path" "$settings_path")"
    row="$(jq -n --arg text "${marker} ${name}" --arg click "$click" '{text: $text, click: $click}')"
    out="$(jq -c --argjson row "$row" '. + [$row]' <<<"$out")"
  done < <(jq -c '.[]' <<<"$vnets_json" 2>/dev/null)
  printf '%s' "$out"
}

# Sketchybar-style pill background flags for the item's `ridge add` call -
# corner-radius/height/padding only, no bg-color: the bg color tracks
# connection state and is set per poll via `ridge set --bg-color`, same
# convention as the mindfulness plugin's colored-by-state item.
_pill_flags() {
  local out=""
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- '--bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

##############################################################################
# I/O: talks to netbird/warp-cli and ridge.
##############################################################################

# Set once each backend's first "unknown" classification has been logged, so
# it prints at most once per process lifetime instead of once per poll tick -
# same idea as media.sh's _media_logged_missing.
_vpn_logged_unknown_netbird=0
_vpn_logged_unknown_warp=0

_vpn_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/ridge/vpn"
  mkdir -p "$dir" && chmod 0700 "$dir"
  printf '%s' "$dir"
}

_vpn_inflight_flag() { printf '%s/inflight' "$(_vpn_state_dir)"; }

# True while a netbird-toggle/warp-toggle/warp-reauth action is running. A
# flag older than 1 minute is ignored so a crash mid-action cannot freeze the
# poll loop forever - ported from the sketchybar source's
# `find "$FLAG" -mmin +1` staleness check in vpn.sh/vpn_click.sh.
_vpn_inflight_active() {
  local flag; flag="$(_vpn_inflight_flag)"
  [[ -f "$flag" ]] && [[ -z "$(find "$flag" -mmin +1 2>/dev/null)" ]]
}

_vpn_set_inflight() { touch "$(_vpn_inflight_flag)"; }
_vpn_clear_inflight() { rm -f "$(_vpn_inflight_flag)"; }

# One poll tick: classify both backends and paint the bar item + popup rows.
# Also used for the instant-feedback repaint after a toggle/reauth click.
_vpn_poll_and_paint() {
  local nb_present=false warp_present=false
  if [[ -x "$SETTING_netbird_bin" ]]; then nb_present=true; fi
  if [[ -x "$SETTING_warp_bin" ]]; then warp_present=true; fi

  # A missing binary is simply not-installed (folded into "disconnected"),
  # never "unknown" - "unknown" is reserved for a genuine parse failure of
  # output from a binary that DID run. Skip the exec entirely when absent so
  # a missing CLI doesn't cost a failed process spawn every tick.
  local nb_state warp_state
  if [[ "$nb_present" == "true" ]]; then
    local nb_raw; nb_raw="$(_timeout "$SETTING_status_timeout_seconds" "$SETTING_netbird_bin" status 2>/dev/null)"
    nb_state="$(_vpn_classify_netbird "$nb_raw")"
  else
    nb_state="disconnected"
  fi
  if [[ "$warp_present" == "true" ]]; then
    local warp_raw; warp_raw="$(_timeout "$SETTING_status_timeout_seconds" "$SETTING_warp_bin" status 2>/dev/null)"
    warp_state="$(_vpn_classify_warp "$warp_raw")"
  else
    warp_state="disconnected"
  fi

  if [[ "$nb_state" == "unknown" && "$_vpn_logged_unknown_netbird" -eq 0 ]]; then
    echo "vpn: netbird status output could not be classified - treating as unknown" >&2
    _vpn_logged_unknown_netbird=1
  fi
  if [[ "$warp_state" == "unknown" && "$_vpn_logged_unknown_warp" -eq 0 ]]; then
    echo "vpn: warp-cli status output could not be classified - treating as unknown" >&2
    _vpn_logged_unknown_warp=1
  fi

  local paint_fields bg icon_color glyph
  paint_fields="$(_vpn_paint_state "$nb_state" "$warp_state" "$SETTING_connected_color" "$SETTING_warp_accent_color" "$SETTING_netbird_icon_color" "$SETTING_off_color" "$SETTING_unknown_color" "$SETTING_bg_color")"
  IFS='|' read -r bg icon_color glyph <<<"$paint_fields"
  ridge set "$ITEM_ID" --icon "$glyph" --icon-color "$icon_color" --bg-color "$bg" 2>/dev/null || true

  local header_fields header_label header_glyph header_color
  header_fields="$(_vpn_header_fields "$nb_state" "$warp_state" "$SETTING_connected_color" "$SETTING_off_color")"
  IFS='|' read -r header_label header_glyph header_color <<<"$header_fields"

  local netbird_label warp_label
  netbird_label="$(_vpn_toggle_label "NetBird" "$nb_state")"
  warp_label="$(_vpn_toggle_label "Cloudflare WARP" "$warp_state")"

  local script_path="${PLUGIN_ROOT}/vpn.sh" settings_path="${RIDGE_PLUGIN_SETTINGS:-}"
  local netbird_click warp_click reauth_click
  netbird_click="$(build_reexec_cmd "VPN_ACTION=netbird-toggle" "$script_path" "$settings_path")"
  warp_click="$(build_reexec_cmd "VPN_ACTION=warp-toggle" "$script_path" "$settings_path")"
  reauth_click="$(build_reexec_cmd "VPN_ACTION=warp-reauth" "$script_path" "$settings_path")"

  local reauth_visible=false
  if [[ "$warp_present" == "true" && "$warp_state" == "connected" ]]; then reauth_visible=true; fi

  # Exit nodes are only listable while NetBird is connected (matches the
  # sketchybar source); vnets are listed whenever warp-cli is present, since
  # `warp-cli vnet` reports (and lets you pre-select) them regardless of
  # connection state.
  local exit_nodes_json='[]' vnets_json='[]'
  if [[ "$nb_present" == "true" && "$nb_state" == "connected" ]]; then
    local nb_networks_raw
    nb_networks_raw="$(_timeout "$SETTING_status_timeout_seconds" "$SETTING_netbird_bin" networks list 2>/dev/null)"
    exit_nodes_json="$(_vpn_parse_netbird_exit_nodes "$nb_networks_raw")"
  fi
  if [[ "$warp_present" == "true" ]]; then
    local warp_vnet_raw
    warp_vnet_raw="$(_timeout "$SETTING_status_timeout_seconds" "$SETTING_warp_bin" -j vnet 2>/dev/null)"
    vnets_json="$(_vpn_parse_warp_vnets "$warp_vnet_raw")"
  fi

  local exit_rows_json vnet_rows_json
  exit_rows_json="$(_vpn_exit_node_rows_json "$exit_nodes_json" "$script_path" "$settings_path")"
  vnet_rows_json="$(_vpn_vnet_rows_json "$vnets_json" "$script_path" "$settings_path")"

  local rows_json
  rows_json="$(_vpn_popup_rows_json "$header_label" "$header_glyph" "$header_color" \
    "$nb_present" "$netbird_label" "$netbird_click" \
    "$warp_present" "$warp_label" "$warp_click" \
    "$reauth_visible" "$reauth_click" \
    "$exit_rows_json" "$vnet_rows_json")"
  ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
}

# Entry point for VPN_ACTION=<netbird-toggle|warp-toggle|warp-reauth|
# netbird-exit-select|netbird-exit-deselect|warp-vnet-select>: close the
# popup first for responsiveness, set the in-flight guard so the poll loop
# yields, run the actual command (NOT timeout-wrapped - connecting/selecting
# can legitimately take longer than a short alarm, matches the sketchybar
# source's vpn_action.sh not wrapping these either), clear the guard, repaint.
_vpn_handle_action() {
  local action="$1"
  ridge popup hide "$ITEM_ID" 2>/dev/null || true
  _vpn_set_inflight

  case "$action" in
    netbird-toggle)
      if [[ -x "$SETTING_netbird_bin" ]]; then
        local raw nb_state
        raw="$(_timeout "$SETTING_status_timeout_seconds" "$SETTING_netbird_bin" status 2>/dev/null)"
        nb_state="$(_vpn_classify_netbird "$raw")"
        if [[ "$nb_state" == "connected" ]]; then
          "$SETTING_netbird_bin" down >/dev/null 2>&1 || true
        else
          # NetBird and WARP are mutually exclusive - drop WARP first.
          if [[ -x "$SETTING_warp_bin" ]]; then "$SETTING_warp_bin" disconnect >/dev/null 2>&1 || true; fi
          "$SETTING_netbird_bin" up >/dev/null 2>&1 || true
        fi
      fi
      ;;
    warp-toggle)
      if [[ -x "$SETTING_warp_bin" ]]; then
        local raw warp_state
        raw="$(_timeout "$SETTING_status_timeout_seconds" "$SETTING_warp_bin" status 2>/dev/null)"
        warp_state="$(_vpn_classify_warp "$raw")"
        if [[ "$warp_state" == "connected" ]]; then
          "$SETTING_warp_bin" disconnect >/dev/null 2>&1 || true
        else
          # NetBird and WARP are mutually exclusive - drop NetBird first.
          if [[ -x "$SETTING_netbird_bin" ]]; then "$SETTING_netbird_bin" down >/dev/null 2>&1 || true; fi
          "$SETTING_warp_bin" connect >/dev/null 2>&1 || true
        fi
      fi
      ;;
    warp-reauth)
      # The Teams session can expire while the tunnel still reports Connected
      # with no auto-prompt, so this is the manual trigger for the Access SSO
      # browser flow - the notification is the only sign it's happening.
      if [[ -x "$SETTING_warp_bin" ]]; then
        osascript -e 'display notification "Opening WARP re-authentication…" with title "VPN"' >/dev/null 2>&1 || true
        "$SETTING_warp_bin" debug access-reauth >/dev/null 2>&1 || true
      fi
      ;;
    netbird-exit-select)
      # VPN_EXIT_ID is the raw route id from `netbird networks list`'s "- ID:"
      # field; it arrives as a real env var via build_reexec_cmd/shq, never
      # string-interpolated, so a hostile id can't break out of this command.
      if [[ -x "$SETTING_netbird_bin" && -n "${VPN_EXIT_ID:-}" ]]; then
        "$SETTING_netbird_bin" networks select "$VPN_EXIT_ID" >/dev/null 2>&1 || true
      fi
      ;;
    netbird-exit-deselect)
      if [[ -x "$SETTING_netbird_bin" && -n "${VPN_EXIT_ID:-}" ]]; then
        "$SETTING_netbird_bin" networks deselect "$VPN_EXIT_ID" >/dev/null 2>&1 || true
      fi
      ;;
    warp-vnet-select)
      if [[ -x "$SETTING_warp_bin" && -n "${VPN_VNET_ID:-}" ]]; then
        # NetBird and WARP are mutually exclusive - drop NetBird first.
        if [[ -x "$SETTING_netbird_bin" ]]; then "$SETTING_netbird_bin" down >/dev/null 2>&1 || true; fi
        "$SETTING_warp_bin" vnet "$VPN_VNET_ID" >/dev/null 2>&1 || true
        "$SETTING_warp_bin" connect >/dev/null 2>&1 || true
      fi
      ;;
  esac

  _vpn_clear_inflight
  _vpn_poll_and_paint
}

main() {
  for dep in jq ridge; do
    if ! _have "$dep"; then echo "vpn: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  load_settings

  if [[ -n "${VPN_ACTION:-}" ]]; then
    _vpn_handle_action "$VPN_ACTION"
    exit 0
  fi

  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "vpn: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (numbers only)
  ridge add "$ITEM_ID" --region "$SETTING_region" --text "" --icon "$VPN_GLYPH_OFF" --icon-color "$SETTING_off_color" --bg-color "$SETTING_bg_color" --click "ridge popup toggle $ITEM_ID" --font "$SETTING_font" $(_pill_flags) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  while true; do
    if ! _vpn_inflight_active; then
      _vpn_poll_and_paint
    fi
    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so
# the guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

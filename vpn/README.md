# vpn plugin

NetBird + Cloudflare WARP connection status, plus a connect/disconnect popup
with exit-node and virtual-network selection. See [Deferred](#deferred) below
for what's not implemented.

## What it does

- One item (`vpn.status`): an icon-only glyph, system-family connected hue
  when either backend is connected (icon color distinguishes NetBird from
  WARP), a greyed-out glyph on the standard pill background when
  disconnected, warning hue when a present binary's status output can't be
  classified.
- Clicking the item opens a popup: a status header, a NetBird connect/
  disconnect toggle, an **Exit Nodes** section (shown only while NetBird is
  connected) listing NetBird's full-tunnel routes with a select/deselect
  toggle per row, a WARP connect/disconnect toggle, a **Virtual Networks**
  section listing WARP's vnets (selecting one switches to WARP), and a WARP
  re-auth action (shown only while WARP is connected). NetBird and WARP are
  mutually exclusive - toggling one on (or selecting a vnet) brings the other
  down first.
- Polls `netbird status` and `warp-cli status` once each per interval, each
  wrapped in a timeout so a hung CLI can never stall the poll loop. Exit
  nodes and vnets are polled the same way, each tick the relevant section is
  shown.

## Requirements

| Dependency | Notes |
|---|---|
| `netbird` | Optional. Resolved via `command -v netbird`, falling back to `/opt/homebrew/bin/netbird`. Skipped entirely (no toggle row, no status probe) when not resolvable. |
| `warp-cli` | Optional. Path from `warp_bin` (default `/usr/local/bin/warp-cli`). Same skip behavior when missing. |
| `jq` | Required. JSON parsing of plugin settings and popup row payloads. |
| `ridge` CLI | Required. On `PATH`; used to reach the running bar over `$RIDGE_SOCKET`. |

## Install

1. Copy this directory to `~/.config/ridge/plugins/vpn/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/vpn/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: vpn
       enabled: true
       settings:
         interval: "5"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `interval` | `3` | Seconds between polls. Non-numeric or zero-equivalent falls back to `3`. |
| `netbird_bin` | (empty - `command -v netbird` at runtime) | Path to the `netbird` binary. Empty resolves via `command -v`, falling back to `/opt/homebrew/bin/netbird`. |
| `warp_bin` | `/usr/local/bin/warp-cli` | Path to the `warp-cli` binary. |
| `status_timeout_seconds` | `5` | Timeout for each `netbird status`/`warp-cli status` probe. |
| `bg_color` | `theme:background` | Pill background when disconnected (the standard idle-pill color other widgets use). |
| `connected_color` | `theme:success` | Bar item background when a backend is connected; popup header color for a NetBird-only connection. |
| `warp_accent_color` | `theme:warning` | Bar item icon color when WARP is (or is among) the connected backend(s). |
| `netbird_icon_color` | `#12161D` | Bar item icon color when only NetBird is connected; glyph color on the unknown-state pill (fixed dark ink for contrast). |
| `off_color` | `theme:secondary` | Glyph + popup header color when disconnected. |
| `unknown_color` | `theme:warning` | Bar item background when a present binary's status output can't be classified as connected or disconnected. |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

`plugin.yaml`'s `settings_schema` maps each key above to a typed control
(slider, enum picker, or color picker) in the GUI Settings window's Plugins
pane - cosmetic only, the plugin script still reads plain strings.

The popup's cyan WARP-connected status header accent is a fixed value
(`#7DCFFF`, Tokyo Night cyan), not a setting - same pattern as the battery
plugin's fixed popup title accent.

## Items it owns

| Id | What |
|---|---|
| `vpn.status` | The glyph item; its popup carries the status header, toggle/re-auth rows, and the Exit Nodes/Virtual Networks sections. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: vpn.` and
`permissions.ops: [add, set, remove, popup]`. `popup` covers both
`ridge popup toggle` (opening the popup) and `ridge popup set-rows`
(rebuilding its rows) - the wire protocol maps both to the single `popup` op.

## Exit nodes and virtual networks

`netbird networks list` has no structured output mode (verified against the
netbird CLI source - only free text), so its exit-node rows are parsed with
an `awk` state machine keyed off the `- ID:`/`Network:`/`Status:` line
prefixes the CLI always prints; any other field or a format change degrades
to an empty section rather than a parse error. `warp-cli -j vnet` **does**
have a real JSON mode, so its vnet rows are parsed with `jq` directly. Both
parsers are pure functions (`_vpn_parse_netbird_exit_nodes`,
`_vpn_parse_warp_vnets`) covered by `tests/exit_vnet.bats` fixtures.

An exit-node row toggles select/deselect per click (a filled/hollow marker
shows selected vs not); a vnet row always selects (switching to WARP,
dropping NetBird first). Route/vnet ids are hostile input - they only ever
reach the click command via `shq`, never string-interpolated.

## Deferred

There's no click-time spinner glyph animation: ridge runs a click as a
detached command via `/bin/sh -c`, with no channel back to animate the icon
mid-flight, so the bar item only repaints once the action finishes (or on
the next poll tick). The in-flight guard in `vpn.sh` still stops the poll
loop from racing an in-flight action; there's just no animated feedback
while one runs.

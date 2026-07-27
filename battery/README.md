# battery plugin

A charge-level glyph with threshold color, plus a details popup. Ported from
sketchybar's `battery.sh`/`battery_popup.sh`.

## What it does

- One item (`battery.status`): a Nerd Font glyph that reflects charge level
  (90-100/60-89/30-59/10-29/<10 band), overridden to a plug glyph while on
  AC power.
- Color reflects the threshold: `crit_color` below `crit_threshold`,
  `warn_color` below `warn_threshold`, else `normal_color`.
- Clicking the item opens a popup with 7 rows: title, charge (percent +
  status), time remaining, power source, health, cycle count, and
  temperature. Rows are rebuilt every poll.
- Polls `pmset -g batt` and `ioreg -rn AppleSmartBattery` once each per
  interval (no subscribe/event source for battery state on macOS).

## Requirements

| Dependency | Notes |
|---|---|
| `pmset` | macOS built-in; charge percent, status, time remaining, power source |
| `ioreg` | macOS built-in; cycle count, health, temperature |
| `jq` | JSON parsing of plugin settings and popup row payloads |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/battery/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/battery/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: battery
       enabled: true
       settings:
         interval: "60"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `interval` | `120` | Seconds between polls. Non-numeric or zero falls back to `120`. |
| `region` | `right` | Bar region for the item. |
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `warn_threshold` | `20` | Percent below which `warn_color` is used. |
| `crit_threshold` | `10` | Percent below which `crit_color` is used. |
| `warn_color` | `theme:warning` | Color at or below `warn_threshold`. |
| `crit_color` | `theme:error` | Color at or below `crit_threshold`. |
| `normal_color` | `theme:primary` | Color above both thresholds. |
| `bg_color` | `theme:background` | Pill background color (sketchybar-style bubble, matching aerospace). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

`plugin.yaml`'s `settings_schema` maps each key above to a typed control
(slider, enum picker, or color picker) in the GUI Settings window's Plugins
pane - cosmetic only, the plugin script still reads plain strings.

## Items it owns

| Id | What |
|---|---|
| `battery.status` | The glyph item; its popup carries the 7 detail rows. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: battery.` and
`permissions.ops: [add, set, remove, popup]`. `popup` covers both
`ridge popup toggle` (opening the details popup) and
`ridge popup set-rows` (rebuilding its rows) - the wire protocol maps both to
the single `popup` op.

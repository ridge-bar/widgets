# cpu plugin

A CPU usage bar-block glyph with threshold color, plus a top-processes
popup. Split out of the former `sysmon` plugin (which bracketed CPU and
memory together) so CPU can be installed on its own. Ported from
sketchybar's `items/sysmon.sh` + `plugins/cpu.sh` + `plugins/sysmon_popup.sh`
+ `plugins/usage_bar.sh`.

## What it does

- One item, `cpu.usage`: an 8-level bar-block glyph (`▁▂▃▄▅▆▇█`) reflecting
  a 0-100% CPU reading. No label - the glyph and its color carry the value.
- Color reflects the threshold: `crit_color` at/above `crit_threshold`,
  `warn_color` at/above `warn_threshold`, else `cpu_color`.
- CPU% is `iostat -c 2 -w 1`'s final line, us+sy columns summed and rounded
  (not `top`, to avoid a full process-table walk).
- Clicking the item opens a popup listing the top 10 processes by CPU.

## Popup CPU% algorithm

Per-process CPU is **not** `ps`'s `pcpu` (a lifetime average that overstates
processes busy long ago and understates ones spiking right now). Instead,
each refresh snapshots every process's cumulative CPU time and computes
`(cs_now - cs_prev) / dt * 100` per pid - the same btop-style instantaneous
reading as the sketchybar source. The snapshot is persisted atomically
(temp+mv) under `${XDG_STATE_HOME:-$HOME/.local/state}/ridge/cpu/cpu_snap`.
A stale or first-run snapshot (no previous sample, or more than 10s since the
last one) falls back to `pcpu` for that pass.

## Simplifications over the sketchybar source

- **Popup-open detection**: the source watches a `/tmp` flag file toggled by
  a separate always-running 1s-cadence poller item. This port instead reads
  `.popupOpen` off `ridge query items` for `cpu.usage` - a single source of
  truth already tracked by ridge core, no flag file needed.
- **Refresh cadence**: the top-process listing only runs (and the popup rows
  only rebuild) at the plugin's normal `interval`, while the popup is open -
  there is no separate faster poller. If you want a snappier popup, lower
  `interval`.
- **Standalone item**: the original shared one bracket + popup with the
  memory item. This plugin owns its own pill and its own single-column
  top-CPU popup; see the `memory` plugin for the memory counterpart.

## Requirements

| Dependency | Notes |
|---|---|
| `iostat` | macOS built-in; CPU sampling |
| `ps` | macOS built-in; per-process CPU sampling |
| `jq` | JSON parsing of plugin settings and popup row payloads |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/cpu/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/cpu/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: cpu
       enabled: true
       settings:
         interval: "5"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `region` | `right` | Bar region for the item. |
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `interval` | `5` | Seconds between polls; also the popup process-row refresh cadence while open. Non-numeric or zero falls back to `5`. |
| `warn_threshold` | `75` | Percent at/above which `warn_color` is used. |
| `crit_threshold` | `90` | Percent at/above which `crit_color` is used. |
| `cpu_color` | `theme:system` | Healthy-band color. |
| `warn_color` | `theme:warning` | Color at/above `warn_threshold`. |
| `crit_color` | `theme:error` | Color at/above `crit_threshold`. |
| `bg_color` | `theme:background` | Pill background color (sketchybar-style bubble). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

`plugin.yaml`'s `settings_schema` maps each key above to a typed control
(slider, enum picker, or color picker) in the GUI Settings window's Plugins
pane - cosmetic only, the plugin script still reads plain strings.

## Items it owns

| Id | What |
|---|---|
| `cpu.usage` | CPU usage glyph; its click toggles the top-processes popup. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: cpu.` and
`permissions.ops: [add, set, remove, popup, query]`.

- `query` grants read-only `ridge query items`, used every poll to check
  `cpu.usage`'s `.popupOpen` field (see above).
- `popup` covers `ridge popup toggle` and `ridge popup set-rows` - the wire
  protocol maps both to the single `popup` op.

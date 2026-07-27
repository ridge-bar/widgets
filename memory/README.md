# memory plugin

A memory usage bar-block glyph with threshold color, plus a top-processes
popup. Split out of the former `sysmon` plugin (which bracketed CPU and
memory together) so memory can be installed on its own.

## What it does

- One item, `memory.usage`: an 8-level bar-block glyph (`▁▂▃▄▅▆▇█`) reflecting
  a 0-100% memory reading. No label - the glyph and its color carry the value.
- Color reflects the threshold: `crit_color` at/above `crit_threshold`,
  `warn_color` at/above `warn_threshold`, else `mem_color`.
- Memory% is `(active + wired + compressor pages) * pagesize / total * 100`
  from `vm_stat`, rounded.
- Clicking the item opens a popup listing the top 10 processes by memory
  (`ps`'s own `-m` sort).

## Limitations

- **Popup-open detection**: reads `.popupOpen` off `ridge query items` for
  `memory.usage` - a single source of truth already tracked by ridge core,
  no flag file needed.
- **Refresh cadence**: the top-process listing only runs (and the popup rows
  only rebuild) at the plugin's normal `interval`, while the popup is open -
  there is no separate faster poller. If you want a snappier popup, lower
  `interval`.
- **Standalone item**: the original shared one bracket + popup with the CPU
  item. This plugin owns its own pill and its own single-column top-memory
  popup; see the `cpu` plugin for the CPU counterpart.

## Requirements

| Dependency | Notes |
|---|---|
| `vm_stat` | macOS built-in; memory sampling |
| `sysctl` | macOS built-in; total memory + page size |
| `ps` | macOS built-in; per-process memory sampling |
| `jq` | JSON parsing of plugin settings and popup row payloads |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/memory/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/memory/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: memory
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
| `mem_color` | `theme:media` | Healthy-band color. |
| `warn_color` | `theme:warning` | Color at/above `warn_threshold`. |
| `crit_color` | `theme:error` | Color at/above `crit_threshold`. |
| `bg_color` | `theme:background` | Pill background color. |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

`plugin.yaml`'s `settings_schema` maps each key above to a typed control
(slider, enum picker, or color picker) in the GUI Settings window's Plugins
pane - cosmetic only, the plugin script still reads plain strings.

## Items it owns

| Id | What |
|---|---|
| `memory.usage` | Memory usage glyph; its click toggles the top-processes popup. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: memory.` and
`permissions.ops: [add, set, remove, popup, query]`.

- `query` grants read-only `ridge query items`, used every poll to check
  `memory.usage`'s `.popupOpen` field (see above).
- `popup` covers `ridge popup toggle` and `ridge popup set-rows` - the wire
  protocol maps both to the single `popup` op.

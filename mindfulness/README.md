# mindfulness plugin

A leaf-glyph countdown to a mindfulness reminder: pulses red and rings a bell
once when overdue, until acknowledged. Ported from sketchybar's
`mindfulness.sh`/`mindfulness_rows.sh`/`mindfulness_interval.sh`/`mindfulness_volume.sh`.

## What it does

- One item (`mindfulness.status`) cycles through three phases: **disabled**
  (orange), **counting** (green, ticking down), **overdue** (pulses green/red
  once a second and rings the bell once per cycle).
- Left-click is contextual on the current phase:
  - disabled -> enable and start the countdown
  - counting -> disable
  - overdue -> shows a random reminder message; a second leaf click, or
    clicking the quote row itself, acknowledges it and restarts the countdown
- Right-click opens a settings popup with the remaining time, an On/Off
  toggle, and draggable sliders for interval and bell volume (see below) -
  the On/Off toggle is the discoverable way to stop the plugin, since the
  left-click disable action only applies while counting. Left/right clicks
  and the quote row's own click all route through the same self-reinvoke
  pattern as `amphetamine`: the click re-execs this script with
  `MINDFULNESS_CLICK=left|right|ack` set.
- The reminder popup's row uses a leaf emoji rather than the item's Nerd Font
  glyph, since popup rows render in the system default font and would
  otherwise show as tofu.
- A left click while overdue asks core (`ridge query popup`, not the
  plugin's own state) whether the quote popup is currently visible: visible
  -> acknowledge; not visible (including a popup dismissed by an outside
  click, Esc, or a ridge restart) -> show a fresh random message.

## Settings vs. state

This plugin splits configuration into two layers - the key adaptation this
port makes over the sketchybar original:

- **Settings** (`plugin.yaml`'s `settings:`/`settings_schema:`, read via
  `$RIDGE_PLUGIN_SETTINGS` like every other plugin) are **defaults only** and
  **read-only** to the running script. They seed the initial state on first
  run and configure fixed things (colors, poll cadences, the bell sound
  path). The script never writes back to this file.
- **Runtime state** (mutated by clicks: enabled on/off, chosen interval,
  chosen volume, and the current countdown-cycle start timestamp) lives in
  plain text files under `${XDG_STATE_HOME:-$HOME/.local/state}/ridge/mindfulness/`,
  one file per key (`enabled`, `interval_min`, `volume`, `cycle_start`). This
  directory is created on first use - delete it to reset the plugin to
  defaults. This is a new convention for this codebase; no other ridge
  plugin currently uses `XDG_STATE_HOME`.

The countdown itself (`cycle_start`) always resets when the plugin process
starts, matching the source's "resets on every bar load" behavior - only the
enabled flag, interval, and volume persist across restarts.

## Settings popup

The remaining-time header is followed by an On/Off toggle, then a draggable
interval slider (1-60 min) and a draggable volume slider (0-100%) - the same
`slider` popup-row type `volume` uses. Dragging a slider live-updates
`interval_min`/`volume` without closing the popup.

The On row is highlighted with `enabled_color` when enabled (Off when
disabled). Clicking On/Off applies immediately: enabling resets the
countdown, same as the left-click enable action.

## Requirements

| Dependency | Notes |
|---|---|
| `afplay` | macOS built-in; plays the bell sound |
| `jq` | JSON parsing of plugin settings and popup row payloads |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/mindfulness/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/mindfulness/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: mindfulness
       enabled: true
       settings:
         default_interval: "20"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `region` | `right` | Bar region for the item. |
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `poll_counting` | `10` | Seconds between paints while counting down. |
| `poll_pulse` | `1` | Seconds between pulse frames while overdue. |
| `poll_disabled` | `30` | Seconds between paints while disabled. |
| `default_interval` | `15` | Countdown length in minutes, seeded on first run. |
| `default_volume` | `100` | Bell volume percent (0 = muted), seeded on first run. |
| `enabled_color` | `theme:success` | Background while counting; also the pulse's "normal" frame and the On-row selection marker. |
| `disabled_color` | `theme:warning` | Background while disabled. |
| `pulse_color` | `theme:error` | Background on the pulse's "red" frame while overdue. |
| `icon_color` | `#12161D` | Glyph color, all phases (fixed dark ink for contrast on the colored pill). |
| `bell_sound` | `/System/Library/Sounds/Submarine.aiff` | Sound file played by `afplay` when overdue. Skipped silently if missing. |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

`default_interval` and `default_volume` only take effect the first time the
plugin runs (they seed the state files); afterward, use the settings popup
sliders or edit the state files directly.

## Items it owns

| Id | What |
|---|---|
| `mindfulness.status` | The glyph item; its popup carries either the reminder message or the settings rows. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: mindfulness.` and
`permissions.ops: [add, set, remove, popup]`. `popup` covers
`ridge popup toggle`, `ridge popup show`, and `ridge popup set-rows` - the
wire protocol maps all three to the single `popup` op.

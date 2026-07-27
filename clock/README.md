# clock plugin

A single clock (time) item. Split out of the [calendar plugin](../calendar),
which now keeps date + meetings only. Ported from sketchybar's `clock.sh`;
no sketchybar-specific behavior carried over.

## What it does

- `clock.time`: a clock, updated every `time_interval` seconds. No icon, no
  popup. Clicking it opens macOS Notification Center (see below).

### Opening Notification Center

Clicking `clock.time` opens macOS Notification Center by AXPress-ing the
Clock menu-bar extra via System Events GUI scripting - the same effect as
clicking the real menu bar clock. The item is selected by its Accessibility
identifier (`AXIdentifier` = `com.apple.menuextra.clock`), not by its "Clock"
description string, so it works regardless of the system locale.

Requires ridge to be granted **Accessibility** access (System Settings >
Privacy & Security > Accessibility). Without it - or if the Clock menu-bar
extra can't be found - the click silently does nothing (no error popup); a
warning is logged once per failure streak to help diagnose a missing grant.

## Requirements

| Dependency | Notes |
|---|---|
| `jq` | JSON parsing of settings |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/clock/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/clock/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: clock
       enabled: true
       settings:
         region: "right"
   ```

## Settings

| Key | Default | Description |
|---|---|---|
| `region` | `right` | Bar region for the item. |
| `font` | `Iosevka Nerd Font` | Item font. |
| `time_format` | `%H:%M:%S` | `date`-style format for the clock text. |
| `time_interval` | `1` | Seconds between clock updates. Non-numeric or zero-equivalent falls back to `1`. |
| `label_color` | `theme:primary` | Text color. |
| `bg_color` | `theme:background` | Item background. |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

## Items it owns

| Id | What |
|---|---|
| `clock.time` | The clock item; click opens Notification Center. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: clock.` and
`permissions.ops: [add, set, remove]`.

## Credit

Ported from `~/.config/sketchybar/plugins/clock.sh`'s clock-rendering logic.

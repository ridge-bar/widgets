# volume plugin

An output/input audio volume glyph with mute, a volume slider, and device
switching in a popup.

## What it does

- One item (`volume.status`): a Nerd Font glyph reflecting output volume,
  label `N%`. Muted or 0% shows `muted_icon`/`muted_color`; otherwise <=33%
  shows `low_icon`, <=66% `mid_icon`, else `high_icon`, all in `icon_color`.
- Reads volume via `osascript`'s `get volume settings` (macOS's software
  mixer). If that returns non-numeric (common when the Mac's own volume is
  routed to an external display over HDMI/DP without a software mixer) and
  `betterdisplay_enabled` is on, falls back to a BetterDisplay DDC read of
  the configured display. If both fail, falls back to the last-known-good
  reading; if that's also empty, shows a blank-state icon (`low_icon`,
  `icon_color`) with no label.
- Clicking the item opens a popup: Output header, Mute/Unmute toggle, a
  draggable output-volume slider, up to 6 output device
  rows (the active device highlighted in `device_active_color`); then the
  same layout again for Input (mute/unmute, a draggable input-volume slider,
  device rows - no BetterDisplay path, input is always the
  software mixer). Rows are rebuilt every poll tick; a slider's thumb
  position is only set when ridge first creates it, so rebuilding rows
  mid-tick never yanks a drag in progress.
- Polls once per `interval` seconds; every click handler (mute, slider,
  device switch) re-execs this script with an env var set, performs
  the action, then repaints immediately instead of waiting for the next poll
  (same self-reinvoke pattern as `amphetamine`/`mindfulness`).

## Notch-width hack removed

- The "notch width" branch (only show the 3-level icon ladder on the
  notched built-in display, else always the high-volume icon) was a
  cosmetic hack tied to physical bar width on a notch.
  Not applicable here - the 3-level ladder is always used.

## Input mute (emulated)

macOS's `osascript "get volume settings"` has no "input muted" property -
only `output volume`, `input volume`, `alert volume`, and `output muted`.
There is nothing to read for input mute, so it's emulated: muting persists
the current input volume to plugin state, then sets input volume to 0;
unmuting restores the persisted value. This means an external change to
input volume while "muted" (e.g. another app raising the mic level) is not
detected - unmuting always restores whatever value was captured at mute
time.

## Requirements

| Dependency | Notes |
|---|---|
| `osascript` | macOS built-in; output/input volume read and write |
| `jq` | JSON parsing of plugin settings and popup row payloads |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |
| `SwitchAudioSource` | Optional; `brew install switchaudio-osx`. Powers the device-switching rows. Device sections are omitted entirely (no error) when absent. |
| `BetterDisplay` | Optional; a paid/free app (not brew-installable) at `/Applications/BetterDisplay.app`. Powers the DDC volume fallback for displays macOS can't mix in software. Only used when `betterdisplay_enabled` is `true` and `betterdisplay_name` is set - off by default since it targets one specific, user-owned display. |

## Install

1. Copy this directory to `~/.config/ridge/plugins/volume/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/volume/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: volume
       enabled: true
       settings:
         interval: "5"
   ```

3. Optional - enable the BetterDisplay DDC fallback for an external monitor
   without a software mixer:

   ```yaml
   plugins:
     - name: volume
       enabled: true
       settings:
         betterdisplay_enabled: "true"
         betterdisplay_name: "AW3423DWF"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `interval` | `5` | Seconds between polls. Non-numeric or zero falls back to `5`. |
| `icon_color` | `theme:primary` | Icon/label color while unmuted and above 0%. |
| `bg_color` | `theme:background` | Item background color. |
| `muted_color` | `theme:error` | Icon/label color while muted or at 0%. |
| `low_icon` | `󰕿` | Icon at 1-33%. Also the blank-state icon when no reading is available. |
| `mid_icon` | `󰖀` | Icon at 34-66%. |
| `high_icon` | `󰕾` | Icon at 67-100%. |
| `muted_icon` | `󰖁` | Icon while muted or at 0%. |
| `device_active_color` | `theme:success` | Popup row color for the currently active output/input device. |
| `betterdisplay_enabled` | `false` | Gates the entire BetterDisplay DDC fallback path. When `false`, BetterDisplay is never invoked. |
| `betterdisplay_name` | `""` (empty) | The `-namelike=` display target for BetterDisplay. Required (non-empty) for the fallback to do anything, even when enabled. |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

`plugin.yaml`'s `settings_schema` maps each key above to a typed control
(slider, enum picker, or color picker) in the GUI Settings window's Plugins
pane - cosmetic only, the plugin script still reads plain strings.

## Items it owns

| Id | What |
|---|---|
| `volume.status` | The glyph item; its popup carries the Output/Input mute, slider, and device rows. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: volume.` and
`permissions.ops: [add, set, remove, popup]`. `popup` covers both
`ridge popup toggle` (opening the popup) and `ridge popup set-rows`
(rebuilding its rows) - the wire protocol maps both to the single `popup`
op.

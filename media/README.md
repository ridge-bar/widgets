# media plugin

Now-playing media controls: a bar glyph reflecting idle/paused/playing state,
plus a popup with title/time, transport, seek, and open-player rows. Ported
from sketchybar's `items/media.sh` + `plugins/media*.sh`.

## What it does

- One item (`media.status`): a Nerd Font glyph for idle/paused/playing,
  optionally with a truncated `"artist - title"` (or title-only) label.
- Polls `nowplaying-cli get title artist playbackRate duration elapsedTime`
  every `interval` seconds, wrapped in a bounded timeout (nowplaying-cli can
  take a few seconds right after wake).
- Clicking the item opens a popup with 8 rows, rebuilt every poll: title,
  time (elapsed / duration), Previous, Play/Pause, Next, Seek -10s, Seek
  +10s, and Open player. There is no slider row type in ridge, so the
  source's seek percentage slider becomes two fixed +/-10s presets, and its
  scrolling label marquee becomes static truncation with an ellipsis.
- Transport, seek, and open-player rows self-reinvoke this script with an
  env var set (`MEDIA_CTRL`, `MEDIA_SEEK`, `MEDIA_OPEN`), then repaint
  immediately instead of waiting for the next poll.
- Degrades gracefully when `nowplaying-cli` is missing: hides the item and
  logs a single warning (not once per poll), while continuing to poll at the
  normal interval in case the binary becomes available later.

## Requirements

| Dependency | Notes |
|---|---|
| `nowplaying-cli` | Reads/controls the system now-playing state; install via `brew install nowplaying-cli` |
| `jq` | JSON parsing of plugin settings and popup row payloads |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Install `nowplaying-cli`:

   ```sh
   brew install nowplaying-cli
   ```

2. Copy this directory to `~/.config/ridge/plugins/media/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/media/`).
3. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: media
       enabled: true
       settings:
         interval: "3"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `region` | `right` | Bar region for the item. |
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `interval` | `3` | Seconds between polls. Non-numeric or zero falls back to `3`. |
| `show_label` | `true` | When `true`, the bar text is a truncated label; when `false`, icon-only. |
| `label_max_length` | `30` | Max bar label length (5-100); truncated text gets a trailing `…`. |
| `idle_icon` | `󰝚` | Glyph shown when nothing is playing. |
| `idle_color` | `theme:secondary` | Icon color when idle. |
| `playing_icon` | `󰏤` | Glyph shown while playing (a pause icon - clicking it pauses). |
| `playing_icon_color` | `theme:primary` | Icon color while playing. |
| `playing_bg_color` | `theme:background` | Background while playing; also the idle background. |
| `paused_icon` | `󰐊` | Glyph shown while media exists but is stopped (a play icon - clicking it resumes). |
| `paused_icon_color` | `#12161D` | Icon color while paused (fixed dark ink for contrast on the paused pill). |
| `paused_bg_color` | `theme:warning` | Background while paused (an attention color, drawing the eye to "click to resume"). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

`plugin.yaml`'s `settings_schema` maps each key above to a typed control
(slider, enum picker, or color picker) in the GUI Settings window's Plugins
pane - cosmetic only, the plugin script still reads plain strings.

## Items it owns

| Id | What |
|---|---|
| `media.status` | The glyph/label item; its popup carries the 8 detail/control rows. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: media.` and
`permissions.ops: [add, set, remove, popup]`. `popup` covers
`ridge popup toggle`, `ridge popup set-rows`, and `ridge popup hide` (used to
close the popup after "Open player") - the wire protocol maps all three to
the single `popup` op.

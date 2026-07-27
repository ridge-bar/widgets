# raycast_focus plugin

Bar toggle for a [Raycast](https://www.raycast.com) Focus session.

## What it does

- Paints one item: an active Focus session shows `on_color`, no session shows
  `off_color` (dark glyph either way).
- Clicking the item toggles the session via deeplink (`open -g
  "raycast://focus/start?..."` / `"raycast://focus/complete"`), passing
  `categories` and `mode` from settings, and records the new state so the
  next click is the opposite.
- **State detection is hybrid.** Raycast keeps Focus state in an encrypted DB
  with no readable flag; the only live signal is Raycast's menu bar - an
  active session's timer item shows a running countdown (`00:35:43`), whose
  title contains a colon. The plugin reads that via System Events when it can:
  - If ridge has **Automation access to System Events** (System Settings >
    Privacy & Security > Automation), detection is live - it reflects sessions
    started or ended anywhere, including from inside Raycast.
  - If that access is not granted (the common case - a background agent's
    Apple events are often denied without a prompt), the plugin falls back to
    the state it tracks from your own toggles. The widget still works: click
    starts, click again stops, color follows. The only limitation is that a
    Focus change made *outside* the widget won't show until your next click
    resyncs it. The fallback is logged once so you know detection isn't live.

Earlier versions counted Raycast's menu bar items (idle=1, active>=2). That is
unreliable on current Raycast (item count can be the same idle and active), so
detection now keys on the countdown-timer title instead.

**AX detection can only confirm a session, never deny one.** On Raycast versions
whose Focus indicator is icon-only (no countdown title), the AX query returns a
well-formed "off" even during an active session. That "off" is treated as "not
detected", not "definitely off", so the widget relies on its own tracked state
there - a Focus session started *outside* the widget may not be detected until
your next click. Positive AX detection still works where Raycast shows a Focus
countdown.

## Requirements

| Dependency | Notes |
|---|---|
| [Raycast.app](https://www.raycast.com) | Must be installed with a Focus-capable license |
| `osascript` | macOS built-in; used to query System Events |
| `perl` | macOS built-in; used for the `_timeout` shim (macOS ships no `timeout` binary) |
| `jq` | JSON parsing of plugin settings |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/raycast_focus/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/raycast_focus/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: raycast_focus
       enabled: true
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `interval` | `15` | Seconds between state polls. |
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `on_color` | `theme:success` | Background color while a session is active. |
| `off_color` | `theme:warning` | Background color while no session is active. |
| `glyph_color` | `#12161D` | Glyph color, both states (fixed dark ink for contrast on the colored pill). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |
| `categories` | `social---edited` | Focus categories to block, as slug tokens (see below). |
| `mode` | `block` | Focus mode passed to the deeplink. |

### Categories are slugs, not display names

Raycast matches `categories` by category token, not display name: built-ins
use their slug (`social`, `news`), and a custom category slugifies its name -
spaces and dashes each become a dash, so a category named "Social - Edited"
becomes `social---edited`. Without `categories`/`mode` set correctly, the
session starts but blocks nothing.

## Items it owns

| Id | What |
|---|---|
| `raycast_focus.status` | The click-to-toggle item. |

## Automation permission (optional, for live detection)

Live detection reads Raycast's menu bar via System Events, which needs **ridge**
granted Automation access to System Events (System Settings > Privacy & Security
> Automation). This is optional: without it the widget self-tracks the state it
toggles and still works (see "What it does"). Grant it if you want the color to
follow Focus sessions you start or stop from *inside* Raycast, not just from the
widget. The plugin logs once when it falls back, so a single log line means live
detection isn't available yet.

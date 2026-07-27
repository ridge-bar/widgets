# amphetamine plugin

Bar toggle for an [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704)
session (keep the Mac awake).

## What it does

- Polls `pmset -g assertions` every `interval` seconds for a line matching
  `\(Amphetamine\).*Prevent`, and paints one item: active session shows a
  filled glyph on `on_color`, no session shows a hollow glyph on `off_color`
  (dark glyph either way, matching the source).
- Clicking the item toggles the session via AppleScript (`osascript`,
  `tell application "Amphetamine" to start new session` / `end session`),
  ported verbatim including the "no `{interval:hours}`" workaround comment -
  passing that option sends a malformed session that can blank the displays.
  The click re-execs this script with `AMPHETAMINE_TOGGLE=1`, which toggles
  and repaints immediately instead of waiting for the next poll.
- Before every toggle, a preflight (`osascript ... tell application
  "Amphetamine" to get version`) confirms ridge can actually reach the app.
  If it fails (Automation access not granted, app not running, sdef
  unreadable), the click does **not** toggle - it paints `warn_color` instead
  and logs the failure once per failure streak, so a mis-toggled/malformed
  AppleEvent can never reach Amphetamine.

## macOS permissions

The first time you click the item, macOS prompts to let ridge control
Amphetamine via **Automation** (System Settings > Privacy & Security >
Automation > [ridge/your terminal] > Amphetamine). Until that's granted, the
preflight check fails and the item shows `warn_color` on every click instead
of toggling - this is deliberate: sending an AppleEvent to Amphetamine
without Automation approval risks a malformed/unhandled event, which has
previously blanked the displays and forced a full macOS re-login.

## Requirements

| Dependency | Notes |
|---|---|
| [Amphetamine.app](https://apps.apple.com/app/amphetamine/id937984704) | Must be installed and its scripting additions enabled |
| `pmset` | macOS built-in |
| `osascript` | macOS built-in |
| `jq` | JSON parsing of plugin settings |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/amphetamine/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/amphetamine/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: amphetamine
       enabled: true
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `interval` | `5` | Seconds between polls of `pmset -g assertions`. |
| `region` | `right` | Bar region for the toggle item. |
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `on_color` | `theme:success` | Background color while a session is active. |
| `off_color` | `theme:warning` | Background color while no session is active. |
| `glyph_color` | `#12161D` | Glyph color, both states (fixed dark ink for contrast on the colored pill). |
| `warn_color` | `theme:warning` | Background color when the preflight check fails (toggle refused). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

## Items it owns

| Id | What |
|---|---|
| `amphetamine.toggle` | The click-to-toggle item. |

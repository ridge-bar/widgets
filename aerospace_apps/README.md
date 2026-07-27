# aerospace_apps plugin

Center window/app list for the focused [AeroSpace](https://github.com/nikitabobko/AeroSpace)
workspace on each monitor: one bubble (app icon + name) per window, click-to-focus.

## What it does

- Per monitor, one bubble (app icon + name) per window on that monitor's
  visible workspace, capped at `max`. The focused window's bubble gets a
  border; a floating window's name gets a pin glyph.
- Click a bubble to focus that window (`aerospace focus --window-id`).
- Driven by `aerospace subscribe --all` (event-push, no polling). On each
  event the focus highlight moves immediately (one focused-window query via
  the reconcile-persisted window-id -> item-id map), then the full desired
  state reconciles; events arriving during the pass coalesce into one
  follow-up reconcile.
- Windows are ordered by on-screen position, not AeroSpace's own list order
  (which is neither the visual order nor stable). `window_positions.js`, a
  small JXA helper, reads window bounds via CoreGraphics in one `osascript`
  call per reconcile (reused from the previous pass when the window set is
  unchanged) - no extra permission needed (only window titles require Screen
  Recording, and this never reads them). If `osascript` is unavailable or
  fails, ordering falls back to AeroSpace's own order. Known limitation:
  accordion-layout windows overlap/cascade on screen, so their on-screen
  x-order is unreliable.

## Requirements

| Dependency | Notes |
|---|---|
| AeroSpace | v0.21+ (needs `aerospace subscribe`) |
| `jq` | JSON parsing of `ridge query` output and plugin settings |
| A Nerd Font | For the bar's own text (window names); tofu/blank without one |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/aerospace_apps/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/aerospace_apps/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: aerospace_apps
       enabled: true
       settings:
         border_focused_color: "#BB9AF7"
   ```

See the sibling [`aerospace_workspaces`](../aerospace_workspaces/README.md)
plugin for the workspace-pill widget.

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.
Colors and dimensions are in [Styling](#styling) below.

| Key | Default | Description |
|---|---|---|
| `region` | `center` | Bar region for the window list. |
| `max` | `8` | Max windows drawn, per monitor. |
| `font` | `Iosevka Nerd Font` | Bar font for app-name labels (empty = bar default). |
| `app_font` | _(empty)_ | Font for app-icon ligatures (current-window icon). Must be set for icons to render; otherwise glyphs show as literal `:app_name:` text. |
| `app_font_style` | `Regular` | Font style/weight for `app_font`. |
| `app_font_size` | `14` | Point size for `app_font`. |
| `update_mode` | `subscribe` | `subscribe` (default) - stream AeroSpace events via `aerospace subscribe`; `trigger` - reconcile on `ridge trigger aerospace_apps` signal; `poll` - reconcile every `poll_interval` seconds. |
| `poll_interval` | `2` | Seconds between reconciles in `poll` mode (ignored in other modes). Non-numeric or zero falls back to `2`. |

## Trigger mode

Set `update_mode: trigger` and drive updates from AeroSpace's own hooks in `~/.aerospace.toml`:

```toml
exec-on-workspace-change = ['/bin/bash', '-c', 'ridge trigger aerospace_apps']
exec-on-focus-change     = ['/bin/bash', '-c', 'ridge trigger aerospace_apps']
```

`ridge` must be on the PATH AeroSpace launches commands with. In trigger mode the bar reconciles only on `ridge trigger aerospace_apps`, so wire every hook whose change should refresh the bar.

## Styling

Tokyo Night by default. Editable per-key under `plugins[].settings` in
`ridge.yaml`, or in the GUI Settings window's Plugins pane; `ridge reload`
(or the GUI's Apply & Reload) applies changes.

| Key | Default | Colors |
|---|---|---|
| `bg_color` | `theme:background` | Bubble background. |
| `border_focused_color` | `theme:system` | Bubble border color for the focused window. |
| `border_width` | `2` | Bubble border width, px, for the focused window; others get width 0. |
| `glyph_color` | `theme:secondary` | Icon + label color for unfocused windows. |
| `glyph_focused_color` | `theme:primary` | Icon + label color for the focused window. |
| `corner_radius` | _(unset)_ | Bubble corner radius, px; unset inherits the bar's global `item_corner_radius`. |
| `height` | _(unset)_ | Bubble height, px; unset inherits the bar's global `item_height`. |
| `pad_left` / `pad_right` | `8` / `8` | Outer padding on each bubble (icon left, label right). |
| `bubble_margin` | `6` | Gap between adjacent app bubbles, px. |

`plugin.yaml`'s `settings_schema` maps each key above to a typed control
(slider, toggle, color picker, or enum picker) in the GUI Settings window's
Plugins pane, instead of a plain text field - cosmetic only, the plugin script
still reads plain strings. See [Manifest](../../README.md#manifest-pluginyaml)
in the top-level README for the full `settings_schema` format.

## Items it owns

| Id pattern | What |
|---|---|
| `aerospace_apps.<M>.<i>.icon` | A window's app-icon item (`app_font`). |
| `aerospace_apps.<M>.<i>.label` | A window's app-name item (bar font; pin glyph if floating). |
| `aerospace_apps.<M>.<i>` (bracket) | Draws one bubble's bg + focus border. |

`<M>` is the sanitized monitor name (any character outside `[A-Za-z0-9_-]`
replaced with `_`); `<i>` is the window's 1-based position, capped at `max`.

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: aerospace_apps.` and
`permissions.ops: [add, set, remove, move, bracket, query, brackets]`. Ridge
sets `RIDGE_PLUGIN_TOKEN` for the process and `ridge` forwards it automatically.

## App icons

`glyphs.sh` maps an app's exact AeroSpace `%{app-name}` to an app-icon
ligature (e.g. `Google Chrome` -> `:google_chrome:`) via the vendored
`__icon_map`/`app_icon` functions, covering ~553 apps; an unmapped app falls
back to `:default:`. The ligature only renders as an icon glyph when
`app_font` is set to a font that defines it - otherwise it shows as literal
text.
To add or change a mapping, edit the case statement in `glyphs.sh` - no
changes to `aerospace-apps-plugin.sh` needed.

## Origin

Split from the former combined `aerospace` plugin (this half owns only the
center window/app list). The workspace pills (and the "AeroSpace down"
status warning) are now the standalone
[`aerospace_workspaces`](../aerospace_workspaces/README.md) plugin. The
service-mode indicator is the separate
[`aerospace_mode`](../aerospace_mode/README.md) plugin.

## Reconnection

The plugin reconnects to `aerospace subscribe` with backoff if the stream
ends (e.g. AeroSpace restarts), and Ridge restarts the plugin itself
(`restart.mode: always`) if it exits. Either way, the next reconcile
diffs the full desired state against `ridge query`, so bubbles resync from
scratch - no persisted state to go stale.

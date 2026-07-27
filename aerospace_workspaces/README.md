# aerospace_workspaces plugin

Dynamic per-monitor [AeroSpace](https://github.com/nikitabobko/AeroSpace) workspace
bubbles: number + per-window glyphs, focus highlight, and click-to-switch.

## What it does

- One bubble per visible/focused workspace: a number item, then one glyph
  item per open window (not deduped, capped at `max_ws_apps`), wrapped in a
  bracket that draws the rounded background.
- The bracket's bg stays dark; a blue border (`border_focused_color`,
  `border_width`) appears when its workspace is focused. The focused
  window's glyph is brighter (`glyph_focused_color`) than the rest.
- Clicking the number runs `aerospace workspace <name>`.
- Driven by `aerospace subscribe --all` (event-push, no polling). On each
  event the focus highlight moves immediately (one focused-workspace query),
  then the full desired state reconciles; events arriving during the pass
  coalesce into one follow-up reconcile.
- Windows within a workspace bubble are ordered by on-screen position, not
  AeroSpace's own list order (which is neither the visual order nor stable).
  `window_positions.js`, a small JXA helper, reads window bounds via
  CoreGraphics in one `osascript` call per reconcile (reused from the
  previous pass when the window set is unchanged) - no extra permission
  needed (only window titles require Screen Recording, and this never reads
  them). If `osascript` is unavailable or fails, ordering falls back to
  AeroSpace's own order. Known limitation: accordion-layout windows
  overlap/cascade on screen, so their on-screen x-order is unreliable.
- Shows a red `aerospace_ws.status` warning item when the `aerospace subscribe`
  event stream disconnects (AeroSpace daemon down/restarting).

## Requirements

| Dependency | Notes |
|---|---|
| AeroSpace | v0.21+ (needs `aerospace subscribe`) |
| `jq` | JSON parsing of `ridge query` output and plugin settings |
| A Nerd Font | For the bar's own text (workspace numbers); tofu/blank without one |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/aerospace_workspaces/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/aerospace_workspaces/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: aerospace_workspaces
       enabled: true
       settings:
         border_focused_color: "#BB9AF7"
   ```

See the sibling [`aerospace_apps`](../aerospace_apps/README.md) plugin for
the center window/app list widget.

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.
Colors and dimensions are in [Styling](#styling) below.

| Key | Default | Description |
|---|---|---|
| `show_empty_workspaces` | `false` | Show workspaces with no windows (unless focused/visible, which always show). |
| `font` | `Iosevka Nerd Font` | Font for the bar's own text (workspace numbers). Empty uses ridge's default (system) font. |
| `font_size` | unset | Optional point size for `font`. |
| `app_font` | _(empty)_ | Font for app-icon ligatures (per-window glyphs). Must be set for icons to render; otherwise glyphs show as literal `:app_name:` text. |
| `app_font_style` | `Regular` | Font style/weight for `app_font`. |
| `app_font_size` | `14` | Point size for `app_font`. |
| `update_mode` | `subscribe` | `subscribe` (default) - stream AeroSpace events via `aerospace subscribe`; `trigger` - reconcile on `ridge trigger aerospace_workspaces` signal; `poll` - reconcile every `poll_interval` seconds. |
| `poll_interval` | `2` | Seconds between reconciles in `poll` mode (ignored in other modes). Non-numeric or zero falls back to `2`. |
| `status_color` | `theme:error` | Color of the `aerospace_ws.status` "AeroSpace down" warning item (shown in `status_region`). |

## Trigger mode

Set `update_mode: trigger` and drive updates from AeroSpace's own hooks in `~/.aerospace.toml`:

```toml
exec-on-workspace-change = ['/bin/bash', '-c', 'ridge trigger aerospace_workspaces']
exec-on-focus-change     = ['/bin/bash', '-c', 'ridge trigger aerospace_workspaces']
```

`ridge` must be on the PATH AeroSpace launches commands with. In trigger mode the bar reconciles only on `ridge trigger aerospace_workspaces`, so wire every hook whose change should refresh the bar.

## Styling

Tokyo Night by default. Editable per-key under `plugins[].settings` in
`ridge.yaml`, or in the GUI Settings window's Plugins pane; `ridge reload`
(or the GUI's Apply & Reload) applies changes.

| Key | Default | Colors |
|---|---|---|
| `bg_color` | `theme:background` | Bubble background. |
| `border_focused_color` | `theme:system` | Bubble border color when its workspace is focused. |
| `border_width` | `2` | Bubble border width, px, when focused; unfocused bubbles get width 0 (no border). |
| `number_color` | `theme:secondary` | The workspace number glyph. |
| `glyph_color` | `theme:primary@0.5` | Per-window app glyphs: the theme primary at 50% opacity, so unfocused glyphs read dimmer than the focused one. |
| `glyph_focused_color` | `theme:primary` | The focused window's app glyph. |
| `corner_radius` | _(unset)_ | Bubble corner radius, px; unset inherits the bar's global `item_corner_radius`. |
| `height` | _(unset)_ | Bubble height, px; unset inherits the bar's global `item_height`. |
| `max_ws_apps` | `5` | Max glyphs shown per workspace; extra windows are not drawn. |
| `num_pad_left` / `num_pad_right` | `8` / `4` | Horizontal padding on the workspace number item. |
| `glyph_pad_left` / `glyph_pad_right` | `8` / `8` | Horizontal padding on each app glyph item. |
| `bubble_margin` | `6` | Gap between workspace bubbles (bracket margin), px. |

Number and glyph items in a bubble share a bracket, so they sit tight against
each other; the padding above is what gives them internal spacing (number and
glyphs close together, clear gap between workspaces).

`plugin.yaml`'s `settings_schema` maps each key above to a typed control
(slider, toggle, color picker, or enum picker) in the GUI Settings window's
Plugins pane, instead of a plain text field - cosmetic only, the plugin script
still reads plain strings. See [Manifest](../../README.md#manifest-pluginyaml)
in the top-level README for the full `settings_schema` format.

`normal_color` (pre-bubble name) still works as a fallback for
`glyph_focused_color`, and `focused_color`/`bg_focused_color` are still
parsed but superseded: focus is now shown as a border
(`border_focused_color`/`border_width`), not a bg-color swap, so
`bg_focused_color` is no longer applied to the bubble background.

## Items it owns

| Id pattern | What |
|---|---|
| `aerospace_ws.<M>.<N>.num` | Workspace number item. |
| `aerospace_ws.<M>.<N>.app.<i>` | One glyph item per open window in that workspace. |
| `aerospace_ws.<M>.<N>` (bracket) | Groups a workspace's number + glyph items into one bubble. |
| `aerospace_ws.status` | Red warning item shown when the `aerospace subscribe` event stream disconnects (AeroSpace daemon down/restarting); hidden again on the next successful reconcile. |

`<M>` is the sanitized monitor name, `<N>` the sanitized workspace name (any
character outside `[A-Za-z0-9_-]` replaced with `_`); `<i>` is the window's
1-based position within the bubble, capped at `max_ws_apps`.

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: aerospace_ws.` and
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
changes to `aerospace-workspaces-plugin.sh` needed.

## Origin

Split from the former combined `aerospace` plugin (this half owns the
workspace bubbles and the "AeroSpace down" status warning). The center
window/app list is now the standalone [`aerospace_apps`](../aerospace_apps/README.md)
plugin. The service-mode indicator is the separate
[`aerospace_mode`](../aerospace_mode/README.md) plugin.

## Reconnection

The plugin reconnects to `aerospace subscribe` with backoff if the stream
ends (e.g. AeroSpace restarts), and Ridge restarts the plugin itself
(`restart.mode: always`) if it exits. Either way, the next reconcile
diffs the full desired state against `ridge query`, so bubbles resync from
scratch - no persisted state to go stale.

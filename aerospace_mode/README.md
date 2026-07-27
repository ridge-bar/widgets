# aerospace_mode plugin

Attention-colored pill showing the active AeroSpace binding mode (e.g.
`SERVICE`), hidden
while AeroSpace is in its `main` mode, positioned immediately before the
`aerospace` plugin's workspace strip. Standalone from
`plugins/aerospace/` on purpose - it does not depend on that plugin running,
only on its item ids.

## What it does

AeroSpace has no command to query its current binding mode, and `ridge
trigger` carries no payload, so the mode name travels through a state file:
your `aerospace.toml` mode bindings write the mode name to the file, then run
`ridge trigger aerospace_mode` (delivered to the plugin as `SIGUSR1`). On
start and on every trigger the plugin reads the file and:

- `main`, empty, or missing -> removes the badge (hidden).
- anything else -> sanitizes it (trim whitespace, cap at 24 chars, allow only
  `[A-Za-z0-9_-]`; anything that fails the allowlist is treated as `main`,
  hidden, with one stderr log line) and shows a gear-icon pill with the
  uppercased mode name.

## Placement: beside the workspace strip, not the front of the region

The badge anchors immediately before whichever `aerospace` plugin item
currently comes first: the `aerospace` container id when the user has placed
a container anchor for it (TASK-88), or else the leading workspace-strip
child (e.g. `aerospace.ws.1.num`). Either way this puts the badge right after
whatever precedes the strip (e.g. a global-menu item) and right before it -
never at the absolute front of the region, which would jump ahead of
everything else there.

Every paint re-queries `ridge query items`, picks that anchor, and:

- **new badge**: `ridge add ... --before <anchor>` (or a plain append if
  `aerospace` has no items yet - a startup-race fallback corrected by the
  next paint once `aerospace` has caught up).
- **existing badge**: `ridge set` for content, then `ridge move --before
  <anchor>` to recover from any displacement (another plugin inserting ahead
  of it) without a mode cycle.

Anchoring on a foreign id (`aerospace.*`) is normally denied by
`PluginPermissionGuard` - a plugin may only position relative to ids it owns.
This plugin's manifest declares `permissions.anchors: [aerospace.]`, an
explicit, auditable escape hatch (the same shape as `permissions.styles`,
scoped to placement instead of restyling) that lets it anchor on the
`aerospace` container id and its children specifically, and nothing else. No
`ridge.yaml`-level ordering key exists (or is needed) - plugin load order in
`ridge.yaml`'s `plugins:` list does not affect item order.

## Requirements

| Dependency | Notes |
|---|---|
| `jq` | JSON parsing of settings and `ridge query items` output |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/aerospace_mode/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/aerospace_mode/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: aerospace_mode
       enabled: true
   ```
3. Wire the mode bindings in `~/.aerospace.toml` (see below) so entering/
   exiting a binding mode writes the state file and triggers a repaint.

## aerospace.toml wiring

Write the mode name to the state file, then trigger the plugin, on entry;
write `main` (or clear the file) and trigger again on exit:

```toml
alt-shift-semicolon = [
    'mode service',
    'exec-and-forget /bin/bash -c ''mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/ridge/aerospace_mode" && printf service > "${XDG_CACHE_HOME:-$HOME/.cache}/ridge/aerospace_mode/mode" && ridge trigger aerospace_mode'''
]

[mode.service.binding]
esc = [
    'mode main',
    'exec-and-forget /bin/bash -c ''printf main > "${XDG_CACHE_HOME:-$HOME/.cache}/ridge/aerospace_mode/mode" && ridge trigger aerospace_mode'''
]
```

Add the matching `exec-and-forget` line to every other binding in
`[mode.service.binding]` that returns to `main` (e.g. this repo's `r`, `f`,
`backspace`, `h`/`j`/`k`/`l`, `shift-down` all end with `'mode main'`).

## Settings

| Key | Default | Description |
|---|---|---|
| `font` | `Iosevka Nerd Font` | Font for the gear glyph + label (add-time only). |
| `bg_color` | `theme:warning` | Pill background (attention hue - the badge signals a non-default mode). |
| `icon_color` | `#12161D` | Gear glyph color (fixed dark ink for contrast on the attention bg). |
| `label_color` | `#12161D` | Mode-name label color (fixed dark ink for contrast on the attention bg). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |
| `padding_left` | `8` | Left padding. |
| `padding_right` | `8` | Right padding. |
| `state_file` | (empty -> `${XDG_CACHE_HOME:-$HOME/.cache}/ridge/aerospace_mode/mode`) | Path the mode name is read from. |

## Items it owns

| Id | What |
|---|---|
| `aerospace_mode.badge` | The mode pill. Present only outside `main` mode. |

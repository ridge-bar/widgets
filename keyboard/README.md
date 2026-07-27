# keyboard plugin

Flag emoji for the current macOS keyboard input source (layout).

## What it does

Polls the current keyboard layout every `interval` seconds and maps its id to a
flag glyph:

| Layout id contains | Glyph |
|---|---|
| `Hungar`/`hungar` | HU flag |
| `US`, `ABC`, or `English`/`english` | US flag |
| anything else | white flag |

macOS posts no event when the input source changes, so polling is the only
option. The layout is read from the **live Carbon TIS API** via a tiny Swift
helper (`keyboard_current.swift`), compiled once and cached under the plugin's
state dir. TIS is authoritative and reflects a switch instantly regardless of
how you switch (input menu, shortcut, Caps Lock). If a Swift toolchain
(`swiftc`, from the Command Line Tools) is not available, it falls back to
`defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID` -
which works for most switches but can lag or miss some paths, the reason the
TIS helper is preferred.

## Requirements

| Dependency | Notes |
|---|---|
| `jq` | JSON parsing of the plugin settings file |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |
| `swiftc` | Optional (Command Line Tools); compiles the live-layout helper. Absent -> falls back to `defaults`. |

## Install

1. Copy this directory to `~/.config/ridge/plugins/keyboard/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/keyboard/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: keyboard
       enabled: true
       region: right          # placement is set here, not in settings
   ```

## Settings

| Key | Default | Description |
|---|---|---|
| `interval` | `1` | Seconds between polls. Non-numeric or zero falls back to `1`. |
| `bg_color` | `theme:background` | Pill background color (matching aerospace). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

## Items it owns

| Id | What |
|---|---|
| `keyboard.layout` | The flag item. |

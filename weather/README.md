# weather plugin

Condition glyph + current temperature from [wttr.in](https://wttr.in), with a
popup for current conditions and a 3-day forecast.

## What it does

Fetches `https://wttr.in/<location>?format=j1` (cached, refetched when the
cache is missing or older than ~5/6 of `interval`), picks a condition glyph +
color by matching the current description (thunder, snow/blizzard, sleet/ice,
rain/drizzle/shower, fog/mist/haze, overcast, cloud, sunny/clear, or a
default), and highlights the item's background when rain or a storm is
current or expected within ~6h (icon and label switch to a dark contrast
color on the highlighted background). Clicking the item opens a popup with
current conditions (now, feels-like, humidity, wind, rain chance, precip) and
a 3-day forecast. A fetch failure keeps the previous cached reading instead of
clobbering the bar.

## Requirements

| Dependency | Notes |
|---|---|
| `jq` | JSON parsing of settings and building popup-row JSON |
| `curl` | Fetches the wttr.in j1 payload |
| `python3` (stdlib only) | Runs the vendored parser/renderer scripts |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |
| Network access to `wttr.in` | No API key required |

## Install

1. Copy this directory to `~/.config/ridge/plugins/weather/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/weather/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: weather
       enabled: true
       region: right          # placement is set here, not in settings
       settings:
         location: "Budapest"
   ```

## Settings

| Key | Default | Description |
|---|---|---|
| `location` | empty | wttr.in location query; URL-encoded before the request. Empty means wttr.in geo-IPs the request, and the popup title shows the resolved area. |
| `interval` | `1800` | Seconds between poll/refresh attempts. Non-numeric or zero-equivalent falls back to `1800`. |
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `thunder_color` | `theme:error` | Icon color for thunder conditions. |
| `snow_color` | `theme:primary` | Icon color for snow/blizzard. |
| `sleet_color` | `theme:system` | Icon color for sleet/ice. |
| `rain_color` | `theme:system` | Icon color for rain/drizzle/shower. |
| `fog_color` | `theme:secondary` | Icon color for fog/mist/haze. |
| `overcast_color` | `theme:secondary` | Icon color for overcast. |
| `cloud_color` | `theme:secondary` | Icon color for (partly) cloudy. |
| `sunny_color` | `theme:warning` | Icon color for sunny/clear. |
| `default_color` | `theme:system` | Icon color when the description matches no bucket. |
| `label_color` | `theme:primary` | Temperature label color (not highlighted). |
| `bg_color` | `theme:background` | Item background (not highlighted). |
| `rain_bg_color` | `theme:system` | Item background when rain is near. |
| `storm_bg_color` | `theme:error` | Item background when a storm is near. |
| `highlight_text_color` | `#12161D` | Icon/label color used on a highlighted (rain/storm) background (fixed dark ink for contrast). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

### Units

wttr.in's j1 payload includes both Celsius and Fahrenheit fields, but the
vendored parser reads only `temp_C` - the plugin is Celsius-only. No `units`
setting is exposed: a
setting that had no effect on behavior would be misleading. Fahrenheit
support would require editing `weather_parse.py`'s and
`weather_popup_render.py`'s field reads.

## Items it owns

| Id | What |
|---|---|
| `weather.status` | The condition glyph + temperature item; click opens the popup. |


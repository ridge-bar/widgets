#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-apps-plugin.sh"
  load_settings
  FIX="${BATS_TEST_DIRNAME}/fixtures"
}

# The widget lists the windows on each monitor's VISIBLE workspace, one
# bubble (icon + label) per window. In the fixture, ws1 (Built-in, visible) has
# kitty + Google Chrome; ws web (DELL, visible) has a floating Firefox. Monitor
# names sanitize to "Built-in_Retina_Display" and "DELL_U2720Q".

@test "desired_state lists the visible workspace's windows as icon+label bubbles" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  [ "$status" -eq 0 ]
  # ws1's two windows -> two bubbles on the Built-in monitor, icon ligature + name.
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.1\\.icon\t.*\t:kitty:\t'
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.1\\.label\t.*\tkitty\t'
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.2\\.icon\t.*\t:google_chrome:\t'
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.2\\.label\t.*\tGoogle Chrome\t'
  # each bubble has a bracket wrapping its icon + label.
  echo "$output" | grep -qE $'^BRACKET\taerospace_apps\\.Built-in_Retina_Display\\.1\taerospace_apps\\.Built-in_Retina_Display\\.1\\.icon,aerospace_apps\\.Built-in_Retina_Display\\.1\\.label\t'
}

@test "desired_state highlights the focused window's bubble only" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  # window 101 (Google Chrome, bubble .2) is focused -> icon highlighted (the bar's
  # selection indicator follows it) + glyph_focused_color; no static border.
  echo "$output" | grep -qE $'^BRACKET\taerospace_apps\\.Built-in_Retina_Display\\.2\t.*\ttheme:background\ttheme:background\t0$'
  echo "$output" | grep -qE $'^HL\taerospace_apps\\.Built-in_Retina_Display\\.2\\.icon\ton$'
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.2\\.icon\t.*\t:google_chrome:\ttheme:primary\t'
  # window 100 (kitty, bubble .1) is unfocused -> not highlighted, glyph_color text.
  echo "$output" | grep -qE $'^BRACKET\taerospace_apps\\.Built-in_Retina_Display\\.1\t.*\ttheme:background\ttheme:background\t0$'
  echo "$output" | grep -qE $'^HL\taerospace_apps\\.Built-in_Retina_Display\\.1\\.icon\toff$'
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.1\\.icon\t.*\ttheme:secondary\t'
}

@test "desired_state click focuses the window by id" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  line="$(echo "$output" | grep $'^ITEM\taerospace_apps.Built-in_Retina_Display.2.icon\t')"
  click="$(cut -f7 <<<"$line")"
  # window-id single-quoted for the sh -c layer.
  [ "$click" = "aerospace focus --window-id '101'" ]
}

@test "desired_state appends a pin glyph to a floating window's label" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  # web ws (DELL) has a single floating Firefox -> label gets the pin glyph.
  line="$(echo "$output" | grep $'^ITEM\taerospace_apps.DELL_U2720Q.1.label\t')"
  label="$(cut -f5 <<<"$line")"
  [ "$label" = "Firefox 󰐃" ]
}

@test "desired_state caps the list at max" {
  SETTING_max=1 run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  # ws1 has two windows; with the cap at 1 only bubble .1 is emitted, not .2.
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.1\\.icon\t'
  ! echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.2\\.'
}

@test "desired_state renders icon items with the sketchybar-app-font ligature text" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.1\\.icon\t.*\t:kitty:\t'
  echo "$output" | grep -qE $'^ITEM\taerospace_apps\\.Built-in_Retina_Display\\.2\\.icon\t.*\t:google_chrome:\t'
}

@test "desired_state emits no items for a hidden workspace" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  # ws2 (Slack) is neither focused nor visible -> no window-list bubble.
  ! echo "$output" | grep -q 'aerospace_apps.*Slack'
}

#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
  load_settings   # defaults (show_empty=false)
  FIX="${BATS_TEST_DIRNAME}/fixtures"
}

@test "desired_state emits number-first, per-window glyph items + bracket" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  [ "$status" -eq 0 ]
  # number item first for ws 1 (text=1, number_color)
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.Built-in_Retina_Display\\.1\\.num\t.*\t1\ttheme:secondary\t'
  # one app item per window in ws 1 (undeduped)
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.Built-in_Retina_Display\\.1\\.app\\.1\t'
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.Built-in_Retina_Display\\.1\\.app\\.2\t'
  # focused window's glyph (2nd, id 101) uses glyph_focused_color, the other glyph_color
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.Built-in_Retina_Display\\.1\\.app\\.2\t.*\ttheme:primary\t'
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.Built-in_Retina_Display\\.1\\.app\\.1\t.*\ttheme:primary@0.5\t'
  # bracket members + bg (always dark, no static border) - focus is shown by the
  # bar's animated selection indicator following the highlighted number item.
  echo "$output" | grep -qE $'^BRACKET\taerospace_ws\\.Built-in_Retina_Display\\.1\taerospace_ws\\.Built-in_Retina_Display\\.1\\.num,aerospace_ws\\.Built-in_Retina_Display\\.1\\.app\\.1,aerospace_ws\\.Built-in_Retina_Display\\.1\\.app\\.2\ttheme:background\ttheme:background\t0$'
  echo "$output" | grep -qE $'^HL\taerospace_ws\\.Built-in_Retina_Display\\.1\\.num\ton$'
}

@test "desired_state number item click targets the workspace" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  # click column (7th field) runs `aerospace workspace <ws>`; ws is single-quoted for the sh -c layer.
  line="$(echo "$output" | grep $'^ITEM\taerospace_ws.Built-in_Retina_Display.1.num\t')"
  click="$(cut -f7 <<<"$line")"
  [ "$click" = "aerospace workspace '1'" ]
}

@test "desired_state uses glyph_color for a non-focused workspace's windows" {
  # ws 2 (Slack) is shown but unfocused; its glyph stays glyph_color, its bracket
  # bg is bg_color, and it has no border (border-color=bg_color, border-width=0).
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.Built-in_Retina_Display\\.2\\.app\\.1\t.*\ttheme:primary@0.5\t'
  echo "$output" | grep -qE $'^BRACKET\taerospace_ws\\.Built-in_Retina_Display\\.2\t.*\ttheme:background\ttheme:background\t0$'
}

@test "desired_state hides empty non-visible workspaces (show_empty=false)" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" ""
  ! echo "$output" | grep -q 'aerospace_ws.Built-in_Retina_Display.3'
}

@test "desired_state with no focused window leaves every glyph unfocused" {
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" ""
  ! echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.[0-9a-z]+\\.app\\.[0-9]+\t.*\ttheme:primary\t'
}

@test "desired_state bakes a hostile workspace name safely into the click" {
  local tmp; tmp="$(mktemp -d)"
  printf 'w; touch %s/pwned x\tDELL U2720Q\ttrue\ttrue\n' "$tmp" >"$tmp/ws"
  run desired_state "${FIX}/monitors.tsv" "$tmp/ws" "${FIX}/windows.tsv" ""
  [ "$status" -eq 0 ]
  line="$(echo "$output" | grep $'^ITEM\taerospace_ws.DELL_U2720Q.w' | head -1)"
  click="$(cut -f7 <<<"$line")"
  # ws name single-quoted -> a later `sh -c` runs it as one argv, no injection.
  [ "$click" = "aerospace workspace 'w; touch ${tmp}/pwned x'" ]
  rm -rf "$tmp"
}

@test "plugin does not use the nonexistent aerospace workspace-is-empty format token" {
  # %{workspace-is-empty} is NOT a valid aerospace --format token (v0.21);
  # using it makes list-workspaces exit non-zero and no pills render.
  ! grep -q '%{workspace-is-empty}' "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
}

@test "desired_state hides a windowless unfocused workspace, shows a windowed one" {
  # ws2 has a window (Slack) but is neither focused nor visible -> shown;
  # ws3 has no window and is neither focused nor visible -> hidden.
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" ""
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.Built-in_Retina_Display\\.2\\.num\t'
  ! echo "$output" | grep -q 'aerospace_ws.Built-in_Retina_Display.3'
}

@test "desired_state renders app items with the app-icon ligature text" {
  # ws1's windows are kitty (app.1) then Google Chrome (app.2), per windows.tsv.
  run desired_state "${FIX}/monitors.tsv" "${FIX}/workspaces.tsv" "${FIX}/windows.tsv" "101"
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.Built-in_Retina_Display\\.1\\.app\\.1\t.*\t:kitty:\t'
  echo "$output" | grep -qE $'^ITEM\taerospace_ws\\.Built-in_Retina_Display\\.1\\.app\\.2\t.*\t:google_chrome:\t'
}

#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/keyboard.sh"
}

@test "layout_glyph maps Hungarian layout ids to the HU flag" {
  [ "$(layout_glyph "com.apple.keylayout.Hungarian")" = "🇭🇺" ]
  [ "$(layout_glyph "com.apple.keylayout.hungarian_qwerty")" = "🇭🇺" ]
}

@test "layout_glyph maps US/English/ABC layout ids to the US flag" {
  [ "$(layout_glyph "com.apple.keylayout.US")" = "🇺🇸" ]
  [ "$(layout_glyph "com.apple.keylayout.ABC")" = "🇺🇸" ]
  [ "$(layout_glyph "com.apple.keylayout.British-English")" = "🇺🇸" ]
}

@test "layout_glyph falls back to the white flag for unknown layouts" {
  [ "$(layout_glyph "com.apple.keylayout.French")" = "🏳️" ]
  [ "$(layout_glyph "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese")" = "🏳️" ]
}

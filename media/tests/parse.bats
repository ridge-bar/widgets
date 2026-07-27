#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/media.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  NP_PLAYING="$(cat "${FIX}/nowplaying_playing.txt")"
  NP_PAUSED="$(cat "${FIX}/nowplaying_paused.txt")"
  NP_IDLE="$(cat "${FIX}/nowplaying_idle.txt")"
  NP_NO_ARTIST="$(cat "${FIX}/nowplaying_no_artist.txt")"
}

@test "_media_field extracts the Nth line in request order" {
  run _media_field "$NP_PLAYING" 1
  [ "$output" = "Random Access Memories" ]
  run _media_field "$NP_PLAYING" 2
  [ "$output" = "Daft Punk" ]
  run _media_field "$NP_PLAYING" 3
  [ "$output" = "1" ]
  run _media_field "$NP_PLAYING" 4
  [ "$output" = "374.000000" ]
  run _media_field "$NP_PLAYING" 5
  [ "$output" = "128.531000" ]
}

@test "_media_classify_state: idle when title is null" {
  local title rate
  title="$(_media_field "$NP_IDLE" 1)"
  rate="$(_media_field "$NP_IDLE" 3)"
  run _media_classify_state "$title" "$rate"
  [ "$output" = "idle" ]
}

@test "_media_classify_state: idle when title is empty" {
  run _media_classify_state "" "1"
  [ "$output" = "idle" ]
}

@test "_media_classify_state: paused when playbackRate is zero-equivalent" {
  local title rate
  title="$(_media_field "$NP_PAUSED" 1)"
  rate="$(_media_field "$NP_PAUSED" 3)"
  run _media_classify_state "$title" "$rate"
  [ "$output" = "paused" ]
}

@test "_media_classify_state: playing when playbackRate is nonzero" {
  local title rate
  title="$(_media_field "$NP_PLAYING" 1)"
  rate="$(_media_field "$NP_PLAYING" 3)"
  run _media_classify_state "$title" "$rate"
  [ "$output" = "playing" ]
}

@test "_media_build_label joins artist and title when artist is present" {
  local artist title
  artist="$(_media_field "$NP_PLAYING" 2)"
  title="$(_media_field "$NP_PLAYING" 1)"
  run _media_build_label "$artist" "$title"
  [ "$output" = "Daft Punk - Random Access Memories" ]
}

@test "_media_build_label falls back to title-only when artist is null" {
  local artist title
  artist="$(_media_field "$NP_NO_ARTIST" 2)"
  title="$(_media_field "$NP_NO_ARTIST" 1)"
  run _media_build_label "$artist" "$title"
  [ "$output" = "Some Podcast Episode" ]
}

@test "_media_build_label falls back to title-only when artist is empty" {
  run _media_build_label "" "Solo Title"
  [ "$output" = "Solo Title" ]
}

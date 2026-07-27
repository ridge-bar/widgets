#!/usr/bin/env bash
set -uo pipefail
# Reference plugin: uses the ridge CLI over $RIDGE_SOCKET to show a live clock.
# Proves launch + persistence + clean shutdown. Install by copying this dir to
# ~/.config/ridge/plugins/heartbeat/ and enabling it in ridge.yaml.
ridge add heartbeat.clock --region right --text "starting" || true
trap 'ridge remove heartbeat.clock 2>/dev/null; exit 0' TERM INT
while true; do
  ridge set heartbeat.clock --text "$(date +%H:%M:%S)" 2>/dev/null || true
  sleep 1
done

#!/bin/bash
# Machine-readable camera status for agents (the MCP server's camera_status tool).
# Usage: status.sh --json
#
# Prints one JSON object (see the contract in docs/mcp-server.md):
#   {"generated_at","paused","vision","last_seen_min","sightings_6h","sightings_12h",
#    "raw_frames_6h","raw_frames_12h","detector_alive","luma","dark","live_url",
#    "subject","pet_names"}
#
# Every number comes from the same place report.sh's caption does — motion-stats.sh over
# events.sh — so an agent and the human-facing report can never disagree. Never sends.
#
#   last_seen_min   minutes since the last sighting in the last 12h; null when nothing was
#                   seen (motion-stats' 9999 sentinel never leaks into JSON). With vision
#                   off/stale it is the raw-burst fallback, and `vision` says so.
#   sightings_*     verified events; null unless vision is "on" — a count of camera noise
#                   must not be presentable as sightings.
#   luma / dark     read from frames/detector-alive.jpg, the detector's own liveness frame,
#                   so asking for status never opens the camera.
#   paused          true still exits 0; the other fields are best-effort.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
BIN="$OJOGATO_HOME/bin"
. "$BIN/ojogato-json.sh"

[ "$1" = "--json" ] || { echo "usage: status.sh --json" >&2; exit 2; }
[ -f "$OJOGATO_HOME/config.env" ] || json_fail 1 "no config at $OJOGATO_HOME/config.env"
source "$OJOGATO_HOME/config.env"

FFMPEG="$BIN/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"
NOW=$(date +%s)
PAUSED=0; [ -f "$OJOGATO_HOME/PAUSED" ] && PAUSED=1

kv() { printf '%s\n' "$1" | grep -oE "(^| )$2=[0-9a-z]+" | cut -d= -f2; }
S6=$("$BIN/motion-stats.sh" 6 2>/dev/null)
S12=$("$BIN/motion-stats.sh" 12 2>/dev/null)
VISION=$(kv "$S12" VISION); [ -n "$VISION" ] || VISION="off"
LMM=$(kv "$S12" LAST_MOTION_MIN)
[ -n "$LMM" ] && [ "$LMM" -ge 9999 ] && LMM=""
MF6=$(kv "$S6" MOTION_FRAMES_LAST_6H);   MF6=${MF6:-0}
MF12=$(kv "$S12" MOTION_FRAMES_LAST_12H); MF12=${MF12:-0}
ME6=""; ME12=""
if [ "$VISION" = "on" ]; then
  ME6=$(kv "$S6" MOTION_EVENTS_LAST_6H); ME12=$(kv "$S12" MOTION_EVENTS_LAST_12H)
fi

ALIVE_IMG="$OJOGATO_HOME/frames/detector-alive.jpg"
ALIVE=0; LUMA=""
if [ -s "$ALIVE_IMG" ]; then
  AGE=$(( NOW - $(stat -f %m "$ALIVE_IMG") ))
  [ "$AGE" -le "${OJOGATO_DETECTOR_STALL_SEC:-180}" ] && ALIVE=1
  [ -n "$FFMPEG" ] && LUMA=$(yavg_of "$FFMPEG" "$ALIVE_IMG")
fi

printf '{"generated_at":%d,"paused":%s,"vision":%s,"last_seen_min":%s,"sightings_6h":%s,"sightings_12h":%s,"raw_frames_6h":%d,"raw_frames_12h":%d,"detector_alive":%s,"luma":%s,"dark":%s,"live_url":%s,"subject":%s,"pet_names":%s}\n' \
  "$NOW" "$(json_bool "$PAUSED")" "$(json_str "$VISION")" "$(json_num_or_null "$LMM")" \
  "$(json_num_or_null "$ME6")" "$(json_num_or_null "$ME12")" "$MF6" "$MF12" \
  "$(json_bool "$ALIVE")" "$(json_num_or_null "$LUMA")" "$(dark_json "$LUMA")" \
  "$(json_str_or_null "$OJOGATO_LIVE_URL")" "$(json_str "${OJOGATO_SUBJECT:-the camera}")" \
  "$(json_str_or_null "$OJOGATO_PET_NAMES")"

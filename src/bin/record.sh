#!/bin/bash
# Rolling recorder: copies the live RTSP stream into 10-minute mp4 segments (no re-encode, ~zero CPU).
# Runs under launchd as com.ojogato.record (KeepAlive).
#
# Segments are FRAGMENTED mp4 (frag_keyframe+empty_moov+default_base_moof) — required
# so clip.sh can cut a playable clip out of the segment that is still being written.
# cleanup.sh enforces retention; the 5s sleep lets mediamtx/capture come up first.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

FFMPEG="$OJOGATO_HOME/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"

mkdir -p "$OJOGATO_HOME/recordings"
sleep 5
exec "$FFMPEG" -hide_banner -loglevel warning \
  -rtsp_transport tcp -i rtsp://127.0.0.1:8554/cam \
  -c copy -f segment -segment_time 600 -reset_timestamps 1 -strftime 1 \
  -segment_format mp4 -segment_format_options movflags=+frag_keyframe+empty_moov+default_base_moof \
  "$OJOGATO_HOME/recordings/%Y%m%d-%H%M%S.mp4"

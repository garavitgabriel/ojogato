#!/bin/bash
# Grabs N still frames S seconds apart from the live stream and prints one absolute file path per line.
# Called by the OpenClaw skill (agent "eyes") or manually. Usage: capture-frames.sh [N=3] [S=10]
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"
set -e

FFMPEG="$OJOGATO_HOME/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"

DIR="$OJOGATO_HOME/frames"
mkdir -p "$DIR"
N=${1:-3}; S=${2:-10}
TS=$(date +%Y%m%d-%H%M%S)
for i in $(seq 1 "$N"); do
  f="$DIR/$TS-$i.jpg"
  "$FFMPEG" -y -loglevel error -rtsp_transport tcp \
    -i rtsp://127.0.0.1:8554/cam -frames:v 1 -q:v 4 "$f"
  echo "$f"
  [ "$i" -lt "$N" ] && sleep "$S"
done
# Keep the frames folder tidy: stills older than 3 days go.
find "$DIR" -name "*.jpg" -mtime +3 -delete

#!/bin/bash
# Cuts an ~9s clip around the newest motion frame from the rolling recordings; prints the clip path (or nothing).
# Called by report.sh (and `ojogato clip`). Exits silently when there is no motion or no matching segment.
#
# Clip-not-still: the last-movement evidence is always a short clip cut at the motion
# frame's mtime — never a "best still" (still-selection proved unreliable: mpdecimate
# also saves the empty "aftermath" frame after the subject leaves).
# Cutting works on the segment still being written because record.sh writes fragmented mp4.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

FFMPEG="$OJOGATO_HOME/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"

REC="$OJOGATO_HOME/recordings"

# Newest motion frame -> the moment we want to show.
LM=$(ls -t "$OJOGATO_HOME/motionframes"/*.jpg 2>/dev/null | head -1)
[ -z "$LM" ] && exit 0
T=$(stat -f %m "$LM")

# Find the 10-min segment whose window contains that moment (segment names are start timestamps).
best=""; bestoff=""
for f in "$REC"/*.mp4; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .mp4)
  st=$(date -j -f "%Y%m%d-%H%M%S" "$b" +%s 2>/dev/null) || continue
  off=$(( T - st ))
  if [ "$off" -ge 0 ] && [ "$off" -lt 600 ]; then best="$f"; bestoff=$off; fi
done
[ -z "$best" ] && exit 0

# Start ~5s before the motion, cut 9s, stream-copy (no re-encode).
START=$(( bestoff - 5 )); [ "$START" -lt 0 ] && START=0
mkdir -p "$OJOGATO_HOME/frames"
OUT="$OJOGATO_HOME/frames/lastmove.mp4"
rm -f "$OUT"
"$FFMPEG" -y -loglevel error -ss "$START" -i "$best" -t 9 -c copy -movflags +faststart "$OUT" 2>/dev/null
[ -s "$OUT" ] && echo "$OUT"

#!/bin/bash
# Cuts a short clip around the last real BURST of motion from the rolling recordings;
# prints the clip path (or nothing). Called by report.sh (and `ojogato clip`).
#
# Clip-not-still: the last-movement evidence is always a clip, never a "best still"
# (still-selection proved unreliable: mpdecimate also saves the empty "aftermath"
# frame after the subject leaves).
#
# Burst-not-newest: anchoring on the single newest motion frame proved unreliable too —
# the newest frame is often a tail-end blip (subject leaving, exposure settling), so a
# clip cut there shows an empty room. A real event (cat/person crossing) produces a
# dense CLUSTER of motion frames; we clip the last cluster, not the last frame.
# Cutting works on the segment still being written because record.sh writes fragmented mp4.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

FFMPEG="$OJOGATO_HOME/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"

REC="$OJOGATO_HOME/recordings"

# Collect motion-frame mtimes, oldest -> newest (bounded to the last 200 frames).
TIMES=$(ls -t "$OJOGATO_HOME/motionframes"/*.jpg 2>/dev/null | head -200 | while read -r f; do
  stat -f %m "$f"
done | sort -n)
[ -z "$TIMES" ] && exit 0

# Find the last burst: frames <= 10s apart belong to one event. Prefer the most recent
# burst with >= 2 frames (real movement); fall back to the newest single frame.
B_START=""; B_END=""; C_START=""; C_END=""; C_N=0; PREV=0
for t in $TIMES; do
  if [ "$PREV" -ne 0 ] && [ $(( t - PREV )) -le 10 ]; then
    C_END=$t; C_N=$(( C_N + 1 ))
  else
    C_START=$t; C_END=$t; C_N=1
  fi
  if [ "$C_N" -ge 2 ]; then B_START=$C_START; B_END=$C_END; fi
  PREV=$t
done
if [ -z "$B_START" ]; then B_START=$C_START; B_END=$C_END; fi

# Clip window: 3s of lead-in before the burst, then the burst plus 3s, capped at 15s.
T0=$(( B_START - 3 ))
DUR=$(( B_END - B_START + 6 ))
[ "$DUR" -lt 9 ] && DUR=9
[ "$DUR" -gt 15 ] && DUR=15

# Find the 10-min segment whose window contains the anchor (segment names are start timestamps).
best=""; bestoff=""
for f in "$REC"/*.mp4; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .mp4)
  st=$(date -j -f "%Y%m%d-%H%M%S" "$b" +%s 2>/dev/null) || continue
  off=$(( T0 - st ))
  if [ "$off" -ge 0 ] && [ "$off" -lt 600 ]; then best="$f"; bestoff=$off; fi
done
[ -z "$best" ] && exit 0

mkdir -p "$OJOGATO_HOME/frames"
OUT="$OJOGATO_HOME/frames/lastmove.mp4"
rm -f "$OUT"
"$FFMPEG" -y -loglevel error -ss "$bestoff" -i "$best" -t "$DUR" -c copy -movflags +faststart "$OUT" 2>/dev/null
[ -s "$OUT" ] && echo "$OUT"

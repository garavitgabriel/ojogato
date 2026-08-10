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
#
# Detector-lag: motion frames are stamped when the JPEG is WRITTEN, which trails the
# moment the camera saw the subject. deflicker=size=N buffers N frames before it can
# emit one (at MOTION_FPS=1 that alone is ~5s), plus RTSP/decode buffering. Measured
# ~6s on the reference install: a person crossing at 21:22:44-46 produced frames stamped
# 21:22:49-51. The old 3s lead-in was SMALLER than the lag, so every clip started after
# the subject had already left — an empty room from a correct detection. We subtract
# OJOGATO_DETECT_LAG before cutting and widen the window to absorb lag jitter.
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

# Find the last burst: frames <= OJOGATO_BURST_GAP seconds apart belong to one event.
# Prefer the most recent burst with >= OJOGATO_BURST_MIN frames (real movement);
# fall back to the newest single frame.
# Gap default is 4s (was 10s): real events produce consecutive-second frames, while
# residual auto-exposure false positives land as isolated frames 5-10s apart — a 10s
# gap let two of those pair up into a fake "burst" and clip an empty room.
GAP="${OJOGATO_BURST_GAP:-4}"
BMIN="${OJOGATO_BURST_MIN:-2}"
B_START=""; B_END=""; C_START=""; C_END=""; C_N=0; PREV=0
for t in $TIMES; do
  if [ "$PREV" -ne 0 ] && [ $(( t - PREV )) -le "$GAP" ]; then
    C_END=$t; C_N=$(( C_N + 1 ))
  else
    C_START=$t; C_END=$t; C_N=1
  fi
  if [ "$C_N" -ge "$BMIN" ]; then B_START=$C_START; B_END=$C_END; fi
  PREV=$t
done
if [ -z "$B_START" ]; then B_START=$C_START; B_END=$C_END; fi

# Shift the burst back by the detector's pipeline lag to get real wall-clock time,
# then take LEAD seconds before it and TAIL after. LEAD/TAIL are deliberately wider
# than the burst itself so a few seconds of lag error still leaves the subject inside.
LAG="${OJOGATO_DETECT_LAG:-6}"
LEAD=4; TAIL=6
E_START=$(( B_START - LAG ))
E_END=$(( B_END - LAG ))
T0=$(( E_START - LEAD ))
DUR=$(( E_END - E_START + LEAD + TAIL ))
[ "$DUR" -lt 12 ] && DUR=12
[ "$DUR" -gt 20 ] && DUR=20

mkdir -p "$OJOGATO_HOME/frames"
OUT="$OJOGATO_HOME/frames/lastmove.mp4"
META="$OJOGATO_HOME/frames/lastmove.meta"
LIST="$OJOGATO_HOME/frames/lastmove.concat"
rm -f "$OUT" "$META" "$LIST"

# Collect EVERY 10-min segment the window touches, not just the one holding its start
# (segment names are start timestamps). An event near a segment boundary spans two files;
# cutting from only the first silently truncates the clip to however little of that file
# remained — which is how a 12s window came back 4s long. Feed the overlapping segments
# through the concat demuxer so the window is contiguous regardless of where it falls.
T_END=$(( T0 + DUR ))
first_st=""
for f in "$REC"/*.mp4; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .mp4)
  st=$(date -j -f "%Y%m%d-%H%M%S" "$b" +%s 2>/dev/null) || continue
  # Nominal 600s span; overlap test tolerates the ~1s/segment writer drift.
  [ "$st" -lt "$T_END" ] && [ $(( st + 600 )) -gt "$T0" ] || continue
  [ -z "$first_st" ] && first_st=$st
  printf "file '%s'\n" "$f" >> "$LIST"
done
[ -s "$LIST" ] || exit 0

# Offset within the first included segment; clamp if the window opens before it exists.
OFF=$(( T0 - first_st ))
[ "$OFF" -lt 0 ] && OFF=0
"$FFMPEG" -y -loglevel error -f concat -safe 0 -i "$LIST" -ss "$OFF" -t "$DUR" \
  -c copy -movflags +faststart "$OUT" 2>/dev/null
rm -f "$LIST"
[ -s "$OUT" ] || exit 0

# Mean luma of the clip. With no IR the room is near-black once the lights go out
# (~8/255 measured, vs ~43 lit), and a "here is the movement" video of a black frame
# reads as a broken camera. report.sh uses this to caption honestly instead of implying
# we saw something. Never gates the clip itself — the footage is still the evidence.
YAVG=$("$FFMPEG" -v info -i "$OUT" -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" \
  -f null - 2>/dev/null | grep -o 'YAVG=[0-9.]*' | cut -d= -f2 | sort -n | tail -1)
{
  echo "CLIP_EVENT_EPOCH=$E_START"
  echo "CLIP_EVENT_HHMM=$(date -r "$E_START" '+%H:%M')"
  echo "CLIP_YAVG=${YAVG:-0}"
} > "$META"

echo "$OUT"

#!/bin/bash
# Cuts a short clip around the last VERIFIED movement from the rolling recordings; prints
# the clip path (or nothing). Called by report.sh (and `ojogato clip`).
#
# Clip-not-still: the last-movement evidence is always a clip, never a "best still"
# (still-selection proved unreliable: mpdecimate also saves the empty "aftermath" frame
# after the subject leaves).
#
# Subject-not-burst. This used to anchor on the last dense CLUSTER of motion frames, on
# the theory that real events cluster and false positives arrive as isolated blips. That
# theory was wrong, and the failure was the reason for this rewrite: on 2026-08-15 the
# clip sent to the phone was captioned "Last movement — 13:34" and showed an empty room,
# because auto-exposure flicker had produced a perfectly good qualifying burst at 13:34
# and the room had in fact been empty since 10:38. No clustering rule can fix that,
# because clustering measures the shape of the noise, not whether anyone was there.
# So the anchor is now an event that ojogato-vision confirmed contains a cat, dog or
# person, and the window is placed over the frames where the subject was actually seen.
#
# Detector-lag: motion frames are stamped when the JPEG is WRITTEN, which trails the
# moment the camera saw the subject. deflicker=size=N buffers N frames before it can emit
# one (at MOTION_FPS=1 that alone is ~5s), plus RTSP/decode buffering. Measured ~6s on the
# reference install: a person crossing at 21:22:44-46 produced frames stamped 21:22:49-51.
# The old 3s lead-in was SMALLER than the lag, so every clip started after the subject had
# already left — an empty room from a correct detection. We subtract OJOGATO_DETECT_LAG
# before cutting and widen the window to absorb lag jitter.
#
# Cutting works on the segment still being written because record.sh writes fragmented mp4.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

BIN="$OJOGATO_HOME/bin"
FFMPEG="$OJOGATO_HOME/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"

REC="$OJOGATO_HOME/recordings"
LOOKBACK="${OJOGATO_CLIP_LOOKBACK_HOURS:-24}"

# --json (for agents): same clip, same lastmove.meta, but print one JSON object instead of
# the path — {"path","event_id","event_hhmm","verdict","duration_s","luma","dark"}, every
# field null when there is nothing to show (exit 0 either way). Never sends anything; this
# script never did. event_id is null for the unverified fallback: no verified event exists.
JSON=0
for a in "$@"; do [ "$a" = "--json" ] && JSON=1; done
nothing() {
  [ "$JSON" = "1" ] && echo '{"path":null,"event_id":null,"event_hhmm":null,"verdict":null,"duration_s":null,"luma":null,"dark":null}'
  exit 0
}
EVENT_ID=""

# ---------------------------------------------------------------- pick the anchor
# VERDICT is what report.sh captions the clip with: pet, person, or unverified.
VERDICT=""; SCORE=""; S_FIRST=""; S_LAST=""; BEST=""
if [ "${OJOGATO_VISION_ENABLED:-1}" != "0" ] && [ -x "$BIN/events.sh" ]; then
  EV=$("$BIN/events.sh" --hours "$LOOKBACK" --last-real 2>/dev/null)
  if [ -n "$EV" ]; then
    EVENT_ID=$(printf '%s' "$EV" | cut -f1)
    VERDICT=$(printf '%s' "$EV" | cut -f5)
    SCORE=$(printf '%s'   "$EV" | cut -f6)
    BEST=$(printf '%s'    "$EV" | cut -f7)
    S_FIRST=$(printf '%s' "$EV" | cut -f9)
    S_LAST=$(printf '%s'  "$EV" | cut -f10)
  fi
fi

if [ -z "$S_FIRST" ] || [ "$S_FIRST" = "0" ]; then
  # No verified event (verifier off, still catching up, or genuinely nothing seen in
  # LOOKBACK hours). Fall back to the old burst anchor so `ojogato clip` still produces
  # something, and mark it unverified so the caption cannot overclaim.
  VERDICT="unverified"; SCORE="0"; EVENT_ID=""
  TIMES=$(ls -t "$OJOGATO_HOME/motionframes"/*.jpg 2>/dev/null | head -200 | while read -r f; do
    stat -f %m "$f"
  done | sort -n)
  [ -z "$TIMES" ] && nothing
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
  S_FIRST=$B_START; S_LAST=$B_END; BEST=$B_START
fi

# ---------------------------------------------------------------- place the window
# Shift back by the detector's pipeline lag to get real wall-clock time, then take LEAD
# seconds before the first sighting and TAIL after the last. LEAD/TAIL are deliberately
# wider than the sighting span so a few seconds of lag error still leaves the subject
# inside the frame.
LAG="${OJOGATO_DETECT_LAG:-6}"
LEAD=4; TAIL=6
MAXDUR=20
E_START=$(( S_FIRST - LAG ))
E_END=$(( S_LAST - LAG ))

T0=$(( E_START - LEAD ))
DUR=$(( E_END - E_START + LEAD + TAIL ))
if [ "$DUR" -gt "$MAXDUR" ]; then
  # A long sighting (a cat settling in at the bowls for five minutes) can't be shown
  # whole, so centre the window on the frame where the recogniser was most confident —
  # by construction the moment the subject was most clearly visible.
  [ -n "$BEST" ] && [ "$BEST" != "0" ] || BEST=$S_FIRST
  T0=$(( BEST - LAG - 5 ))
  DUR=16
fi
[ "$DUR" -lt 12 ] && DUR=12

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
[ -s "$LIST" ] || nothing

# Offset within the first included segment; clamp if the window opens before it exists.
OFF=$(( T0 - first_st ))
[ "$OFF" -lt 0 ] && OFF=0
"$FFMPEG" -y -loglevel error -f concat -safe 0 -i "$LIST" -ss "$OFF" -t "$DUR" \
  -c copy -movflags +faststart "$OUT" 2>/dev/null
rm -f "$LIST"
[ -s "$OUT" ] || nothing

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
  echo "CLIP_VERDICT=${VERDICT:-unverified}"
  echo "CLIP_SCORE=${SCORE:-0}"
} > "$META"

if [ "$JSON" = "1" ]; then
  . "$BIN/ojogato-json.sh"
  # The cut is stream-copied + faststart, so the header carries the real duration.
  DUR_S=$("$FFMPEG" -hide_banner -i "$OUT" 2>&1 | grep -oE 'Duration: [0-9]+:[0-9]{2}:[0-9.]+' | head -1 \
    | sed 's/Duration: //' | awk -F: '{printf "%.2f", $1 * 3600 + $2 * 60 + $3}')
  printf '{"path":%s,"event_id":%s,"event_hhmm":%s,"verdict":%s,"duration_s":%s,"luma":%s,"dark":%s}\n' \
    "$(json_str "$OUT")" "$(json_str_or_null "$EVENT_ID")" "$(json_str "$(date -r "$E_START" '+%H:%M')")" \
    "$(json_str "${VERDICT:-unverified}")" "$(json_num_or_null "$DUR_S")" \
    "$(json_num_or_null "$YAVG")" "$(dark_json "$YAVG")"
  exit 0
fi
echo "$OUT"

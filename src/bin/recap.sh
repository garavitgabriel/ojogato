#!/bin/bash
# Day recap -> Telegram: the day's key VERIFIED moments cut from the rolling recordings,
# stitched into one short video with a time label on each moment. Prints the caption.
# Called by `ojogato recap`, the OpenClaw skill ("send me the recap"), or a digest job.
#
# Usage: recap.sh [--hours N] [--max N] [--no-send]
#   default window is TODAY (local midnight -> now); --hours N means the last N hours.
#   --max      most moments in one video (default OJOGATO_RECAP_MAX, 8)
#   --no-send  build the video and print its path + caption, but don't send it
#
# What counts as a moment. Only events.sh verdicts of pet or person — runs of motion frames
# where ojogato-vision actually recognised a subject. Raw motion frames are not moments: on
# this camera most of them are auto-exposure hunting on an empty room (see events.sh), and a
# recap built from them would be a highlight reel of the camera adjusting to the light.
#
# Which moments are "key". Events are ranked by how many frames showed the subject (a
# long, clearly-seen visit beats a tail glimpsed at the edge of frame), then picked
# greedily with a spacing rule so the reel covers the day instead of eight cuts of the
# same ten-minute zoomie session. Anything the spacing rule skipped refills leftover
# slots, so a quiet day with one busy hour still gets a full reel. The final order is
# chronological — it's a story of the day, not a ranking.
#
# Each moment is centred on the event's most confident frame, shifted back by the detector
# lag (see clip.sh) — the same anchor the last-movement clip uses, for the same reason.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

BIN="$OJOGATO_HOME/bin"
FFMPEG="$BIN/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"
API="https://api.telegram.org/bot${OJOGATO_TELEGRAM_TOKEN}"
REC="$OJOGATO_HOME/recordings"

HOURS=""
MAX="${OJOGATO_RECAP_MAX:-8}"
SEND=1
while [ $# -gt 0 ]; do
  case "$1" in
    --hours)   HOURS="$2"; shift 2 ;;
    --max)     MAX="$2"; shift 2 ;;
    --no-send) SEND=0; shift ;;
    *) echo "recap.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

if [ -f "$OJOGATO_HOME/PAUSED" ]; then echo "ojogato is paused (ojogato off)"; exit 0; fi

LAG="${OJOGATO_DETECT_LAG:-6}"
MOMENT="${OJOGATO_RECAP_MOMENT_SECS:-8}"     # seconds per moment
PRE=3                                        # of which, before the confident frame
SPREAD="${OJOGATO_RECAP_SPREAD_MIN:-15}"     # minutes between picks before refilling
SUBJECT="${OJOGATO_SUBJECT:-the camera}"

NOW=$(date +%s)
if [ -n "$HOURS" ]; then
  SINCE=$(( NOW - HOURS * 3600 ))
  SPAN="last ${HOURS}h"
else
  SINCE=$(date -j -f "%Y%m%d-%H%M%S" "$(date +%Y%m%d)-000000" +%s)
  HOURS=$(( (NOW - SINCE) / 3600 + 1 ))
  SPAN="today"
fi

# One recap at a time: a second "send me the recap" while the first is still encoding
# would race on the same work directory.
LOCK="$OJOGATO_HOME/frames/recap.lock"
mkdir -p "$OJOGATO_HOME/frames"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock older than 10 minutes is a crashed run, not a live one.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rm -rf "$LOCK"; mkdir "$LOCK"
  else
    echo "A recap is already being put together — it'll arrive in a minute."; exit 0
  fi
fi
WORK="$OJOGATO_HOME/frames/recap-work"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK" "$LOCK"' EXIT

send_text() {
  [ "$SEND" = "1" ] && [ -n "${OJOGATO_TELEGRAM_TOKEN}" ] && [ -n "${OJOGATO_TELEGRAM_CHAT}" ] || return 0
  curl -s --max-time 30 -X POST "$API/sendMessage" -d chat_id="$OJOGATO_TELEGRAM_CHAT" \
    --data-urlencode text="$1" >/dev/null
}

# ---------------------------------------------------------------- pick the moments
# events.sh columns: start end frames subject_frames verdict score best_epoch best_frame
#                    subject_first subject_last
ALL=$("$BIN/events.sh" --hours "$HOURS" --real-only 2>/dev/null | awk -F'\t' -v s="$SINCE" '$1 >= s')
TOTAL=$(printf '%s' "$ALL" | grep -c . )

if [ "$TOTAL" -eq 0 ]; then
  CAP="🎬 No recap for ${SPAN} yet — nothing recognisable has crossed the camera."
  send_text "$CAP"; echo "$CAP"; exit 0
fi

PICKED=$(printf '%s\n' "$ALL" | sort -t$'\t' -k4,4nr -k6,6nr | awk -F'\t' -v max="$MAX" -v gap="$(( SPREAD * 60 ))" '
  { row[NR] = $0; be[NR] = $7 }
  END {
    n = 0
    for (i = 1; i <= NR && n < max; i++) {
      ok = 1
      for (j = 1; j <= n; j++) { d = be[i] - pb[j]; if (d < 0) d = -d; if (d < gap) { ok = 0; break } }
      if (ok) { n++; pb[n] = be[i]; used[i] = 1 }
    }
    for (i = 1; i <= NR && n < max; i++) if (!used[i]) { n++; used[i] = 1 }
    for (i = 1; i <= NR; i++) if (used[i]) print row[i]
  }' | sort -n)
N=$(printf '%s\n' "$PICKED" | grep -c .)

# ---------------------------------------------------------------- cut each moment
# Label font: a stock macOS face; if none is found the moments still go out unlabelled.
FONT=""
for f in "/System/Library/Fonts/Supplemental/Arial Bold.ttf" /System/Library/Fonts/Helvetica.ttc; do
  [ -f "$f" ] && { FONT="$f"; break; }
done

i=0; KEPT=0; FIRST_HM=""; LAST_HM=""; PEOPLE=0
while IFS=$'\t' read -r st en nf ns verdict score best bframe sfirst slast; do
  [ -n "$st" ] || continue
  i=$(( i + 1 ))
  [ "$best" != "0" ] || best=$sfirst
  T0=$(( best - LAG - PRE ))
  T_END=$(( T0 + MOMENT ))
  HM=$(date -r $(( best - LAG )) '+%H:%M')

  # Same segment-overlap walk as clip.sh: a moment near a 10-minute boundary spans two
  # files, and cutting from only the first silently shortens it.
  LIST="$WORK/m$i.concat"; first_st=""
  for f in "$REC"/*.mp4; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .mp4)
    s=$(date -j -f "%Y%m%d-%H%M%S" "$b" +%s 2>/dev/null) || continue
    [ "$s" -lt "$T_END" ] && [ $(( s + 600 )) -gt "$T0" ] || continue
    [ -z "$first_st" ] && first_st=$s
    printf "file '%s'\n" "$f" >> "$LIST"
  done
  # Recordings roll off after the retention window; a sighting older than the footage
  # is skipped, not faked.
  [ -s "$LIST" ] || continue
  OFF=$(( T0 - first_st )); [ "$OFF" -lt 0 ] && OFF=0

  if [ "$verdict" = "person" ]; then LABEL="$HM  ·  someone came by"; PEOPLE=$(( PEOPLE + 1 ))
  else LABEL="$HM"; fi
  printf '%s' "$LABEL" > "$WORK/m$i.txt"
  VF="scale=960:-2,fps=12"
  if [ -n "$FONT" ]; then
    VF="$VF,drawtext=fontfile='$FONT':textfile='$WORK/m$i.txt':x=24:y=24:fontsize=34:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=12"
  fi
  # Every moment is re-encoded to identical parameters so the final join can stream-copy.
  "$FFMPEG" -y -nostdin -loglevel error -f concat -safe 0 -i "$LIST" -ss "$OFF" -t "$MOMENT" \
    -an -vf "$VF" -c:v libx264 -preset veryfast -crf 27 -pix_fmt yuv420p \
    "$WORK/m$(printf '%02d' "$i").mp4" 2>>"$WORK/ffmpeg.err"
  [ -s "$WORK/m$(printf '%02d' "$i").mp4" ] || continue
  KEPT=$(( KEPT + 1 ))
  [ -z "$FIRST_HM" ] && FIRST_HM=$HM
  LAST_HM=$HM
done <<EOF
$PICKED
EOF

if [ "$KEPT" -eq 0 ]; then
  CAP="🎬 ${TOTAL} sighting(s) ${SPAN}, but the footage for them has already rolled off the recordings."
  send_text "$CAP"; echo "$CAP"; exit 0
fi

OUT="$OJOGATO_HOME/frames/recap-$(date +%Y%m%d-%H%M).mp4"
ls "$WORK"/m[0-9][0-9].mp4 | sed "s/.*/file '&'/" > "$WORK/all.concat"
"$FFMPEG" -y -nostdin -loglevel error -f concat -safe 0 -i "$WORK/all.concat" -c copy \
  -movflags +faststart "$OUT" 2>>"$WORK/ffmpeg.err"
if [ ! -s "$OUT" ]; then
  CAP="🎬 Recap failed while stitching the moments together — try again in a bit."
  send_text "$CAP"; echo "$CAP"; exit 1
fi

# ---------------------------------------------------------------- caption + send
plural() { [ "$1" = "1" ] && echo "$2" || echo "$2s"; }
SUBJECT_CAP="$(printf '%s' "$SUBJECT" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$SUBJECT" | cut -c2-)"
if [ "$KEPT" = "1" ]; then RANGE="at ${FIRST_HM}"; else RANGE="${FIRST_HM} → ${LAST_HM}"; fi
CAP="🎬 ${SUBJECT_CAP}, ${SPAN}: ${KEPT} $(plural "$KEPT" moment), ${RANGE}"
[ "$TOTAL" -gt "$KEPT" ] && CAP="$CAP (best ${KEPT} of ${TOTAL} sightings)"
[ "$PEOPLE" -gt 0 ] && CAP="$CAP
👤 ${PEOPLE} of them $( [ "$PEOPLE" = "1" ] && echo "is a person" || echo "are people")."

if [ "$SEND" = "0" ] || [ -z "${OJOGATO_TELEGRAM_TOKEN}" ] || [ -z "${OJOGATO_TELEGRAM_CHAT}" ]; then
  echo "$OUT"; echo "$CAP"; exit 0
fi

# Check the API's answer: a silent failure here would leave the agent announcing a video
# that never arrived.
RESP=$(curl -s --max-time 180 -F chat_id="$OJOGATO_TELEGRAM_CHAT" -F video=@"$OUT" \
  -F supports_streaming=true -F caption="$CAP" "$API/sendVideo")
if ! printf '%s' "$RESP" | grep -q '"ok":true'; then
  echo "recap.sh: Telegram rejected the video: $(printf '%s' "$RESP" | head -c 200)" >&2
  echo "🎬 Recap built (${KEPT} moments) but Telegram didn't accept the video — saved at $OUT"
  exit 1
fi

# Keep the last few recaps on disk for re-sending; they're small.
ls -t "$OJOGATO_HOME/frames"/recap-*.mp4 2>/dev/null | tail -n +8 | while read -r f; do rm -f "$f"; done
echo "$CAP"

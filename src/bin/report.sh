#!/bin/bash
# Status report -> Telegram: live snapshot photo + activity caption + ~9s last-movement clip; prints the caption.
# Called by `ojogato report`, the OpenClaw skill, or digest cron jobs. Usage: report.sh [now|digest] [--recap]
#   --recap  send the day's recap video (recap.sh) in place of the last-movement clip —
#            the evening digest uses it, so the day ends with its highlights, not one clip.
#
# Sends via the plain Telegram Bot API (curl) using OJOGATO_TELEGRAM_TOKEN/CHAT — no
# agent framework in the loop. Last-movement evidence is clip.sh's clip, never a
# guessed still (still-selection caught the empty aftermath frame; clips replaced it).
MODE=${1:-now}
RECAP=0; [ "$2" = "--recap" ] && RECAP=1
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

BIN="$OJOGATO_HOME/bin"
FFMPEG="$BIN/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"
API="https://api.telegram.org/bot${OJOGATO_TELEGRAM_TOKEN}"

if [ -f "$OJOGATO_HOME/PAUSED" ]; then echo "ojogato is paused (ojogato off)"; exit 0; fi

SUBJECT="${OJOGATO_SUBJECT:-the camera}"
# 🐱 for cat subjects, 📷 otherwise (bash 3.2: no ${var,,}, lowercase via tr).
case "$(printf '%s' "$SUBJECT" | tr '[:upper:]' '[:lower:]')" in
  *cat*) EMOJI="🐱" ;;
  *)     EMOJI="📷" ;;
esac

# Activity summary (6h and 12h windows).
#
# What gets reported is VERIFIED events — runs of motion frames in which ojogato-vision
# actually recognised a cat, dog or person. It used to be raw frame counts, and those had
# stopped meaning anything: on 2026-08-15 this line claimed "243 motion moments last 6h"
# over a room that had been empty since morning, because the webcam's auto-exposure
# hunting trips mpdecimate all day long. A number that counts the camera's own gain
# changes is worse than no number, because it reads as cats.
S6=$("$BIN/motion-stats.sh" 6); S12=$("$BIN/motion-stats.sh" 12)
LMM=$(echo "$S6" | grep -oE 'LAST_MOTION_MIN=[0-9]+' | cut -d= -f2); LMM=${LMM:-9999}
MF6=$(echo "$S6" | grep -oE 'MOTION_FRAMES_LAST_6H=[0-9]+' | cut -d= -f2)
MF12=$(echo "$S12" | grep -oE 'MOTION_FRAMES_LAST_12H=[0-9]+' | cut -d= -f2)
ME6=$(echo "$S6" | grep -oE 'MOTION_EVENTS_LAST_6H=[0-9]+' | cut -d= -f2)
ME12=$(echo "$S12" | grep -oE 'MOTION_EVENTS_LAST_12H=[0-9]+' | cut -d= -f2)
VSTATE=$(echo "$S6" | grep -oE 'VISION=[a-z]+' | cut -d= -f2)

if [ "$LMM" -ge 9999 ]; then LASTSEEN="nothing seen yet"
elif [ "$LMM" -lt 60 ]; then LASTSEEN="last seen ${LMM} min ago"
else LASTSEEN="last seen $((LMM/60))h $((LMM%60))m ago"; fi

# Plural-aware, and honest about which regime produced the numbers. With the verifier off
# or stale we are back to counting raw frames, and the caption has to say so rather than
# quietly presenting flicker as sightings.
plural() { [ "$1" = "1" ] && echo "$2" || echo "$2s"; }
if [ "$VSTATE" = "on" ] && [ -n "$ME6" ]; then
  ACTIVITY="Activity — ${ME6} $(plural "$ME6" sighting) in 6h, ${ME12} in 12h."
elif [ "$VSTATE" = "stale" ]; then
  ACTIVITY="Activity — ${MF6} raw motion frames last 6h, ${MF12} last 12h.
⚠️ Subject verification is stalled, so these count camera noise as well as ${SUBJECT}."
else
  ACTIVITY="Activity — ${MF6} raw motion frames last 6h, ${MF12} last 12h (unverified)."
fi

# Live snapshot from the loopback stream.
mkdir -p "$OJOGATO_HOME/frames"
SNAP="$OJOGATO_HOME/frames/snap-$(date +%H%M%S).jpg"
"$FFMPEG" -y -loglevel error -rtsp_transport tcp -i rtsp://127.0.0.1:8554/cam \
  -frames:v 1 -q:v 4 -update 1 "$SNAP" 2>/dev/null

# Is the room actually lit? At max sensor gain a near-black frame is mostly grain, and
# mpdecimate counts grain as change — so motion counts inflate in the dark while the
# footage shows nothing. Measured: ~8/255 lights-out vs ~43 lit. Say which regime we
# are in instead of presenting a dark-inflated count as if it were cats.
SNAP_YAVG=""
if [ -s "$SNAP" ]; then
  SNAP_YAVG=$("$FFMPEG" -v info -i "$SNAP" -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" \
    -f null - 2>/dev/null | grep -o 'YAVG=[0-9.]*' | cut -d= -f2 | head -1)
fi
DARK=0
if [ -n "$SNAP_YAVG" ] && awk "BEGIN{exit !($SNAP_YAVG < ${OJOGATO_DARK_YAVG:-16})}"; then DARK=1; fi

if [ "$MODE" = "digest" ]; then LEAD="$EMOJI Digest on ${SUBJECT} ($(date '+%a %H:%M'))"
else LEAD="$EMOJI Checking on ${SUBJECT} ($(date '+%H:%M'))"; fi
CAP="$LEAD: ${LASTSEEN}. ${ACTIVITY}"
if [ "$DARK" = "1" ]; then CAP="$CAP
🌑 Lights are off — no night vision, so counts run high on sensor noise and clips show nothing."; fi
if [ -n "${OJOGATO_LIVE_URL}" ]; then CAP="$CAP
▶️ Watch live: ${OJOGATO_LIVE_URL} (needs Tailscale)"; fi

if [ -z "${OJOGATO_TELEGRAM_TOKEN}" ] || [ -z "${OJOGATO_TELEGRAM_CHAT}" ]; then
  echo "report.sh: Telegram not configured (OJOGATO_TELEGRAM_TOKEN/CHAT empty) — printing only" >&2
  echo "$CAP"
  exit 0
fi

# Photo + caption (or text-only fallback when the stream is down).
if [ -s "$SNAP" ]; then
  curl -s -F chat_id="$OJOGATO_TELEGRAM_CHAT" -F photo=@"$SNAP" -F caption="$CAP" \
    "$API/sendPhoto" >/dev/null
else
  curl -s -X POST "$API/sendMessage" -d chat_id="$OJOGATO_TELEGRAM_CHAT" \
    --data-urlencode text="$CAP
(snapshot failed — stream may be down)" >/dev/null
fi

# Evening digest: the day's recap video replaces the single last-movement clip. recap.sh
# sends its own video (or its own "nothing to show" note) and prints one line.
RECAP_LINE=""
if [ "$RECAP" = "1" ] && [ -x "$BIN/recap.sh" ]; then
  RECAP_LINE=$("$BIN/recap.sh" 2>/dev/null | tail -1)
else
# Short clip of the last real movement (shows the subject, not a guessed still).
# The timestamp comes from clip.sh's lag-corrected event time, NOT the newest motion
# frame's filename — frame filenames trail the real event by ~6s (see clip.sh), so the
# old caption named a moment several seconds after the subject had already left.
CLIP=$("$BIN/clip.sh" 2>/dev/null)
META="$OJOGATO_HOME/frames/lastmove.meta"
CT=""; CLIP_YAVG=""; CLIP_VERDICT=""
if [ -f "$META" ]; then
  CT=$(grep -oE 'CLIP_EVENT_HHMM=.*' "$META" | cut -d= -f2)
  CLIP_YAVG=$(grep -oE 'CLIP_YAVG=[0-9.]*' "$META" | cut -d= -f2)
  CLIP_VERDICT=$(grep -oE 'CLIP_VERDICT=[a-z]*' "$META" | cut -d= -f2)
fi
if [ -z "$CT" ]; then
  LM=$(ls -t "$OJOGATO_HOME/motionframes"/*.jpg 2>/dev/null | head -1)
  if [ -n "$LM" ]; then b=$(basename "$LM"); CT="${b:9:2}:${b:11:2}"; fi
fi
if [ -n "$CLIP" ] && [ -s "$CLIP" ]; then
  # Name what was actually recognised. "Last movement" was the old wording and it was a
  # promise the system could not keep — it meant "pixels changed here", which is how an
  # empty room got captioned as movement. The species word comes from configuration, not
  # from the recogniser: Vision's cat/dog split is unreliable at this resolution, so the
  # honest claim is "an animal", named with the household's own words.
  # bash 3.2 has no ${var^} and BSD sed has no \U, so sentence-case the long way.
  SUBJECT_CAP="$(printf '%s' "$SUBJECT" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$SUBJECT" | cut -c2-)"
  case "$CLIP_VERDICT" in
    pet)    VCAP="🎥 ${SUBJECT_CAP} at ${CT}" ;;
    person) VCAP="🎥 Someone came by at ${CT}" ;;
    *)      VCAP="🎥 Possible movement — ${CT}
❓ Nothing recognisable in frame; this may just be the camera adjusting to the light." ;;
  esac
  # No IR: below the dark threshold nothing in the clip is actually visible, so say so
  # rather than shipping a black video that reads as a camera fault.
  if [ -n "$CLIP_YAVG" ] && awk "BEGIN{exit !($CLIP_YAVG < ${OJOGATO_DARK_YAVG:-16})}"; then
    VCAP="$VCAP
🌑 Room was dark — nothing is visible in this clip. Leave a light on for usable night footage."
  fi
  curl -s -F chat_id="$OJOGATO_TELEGRAM_CHAT" -F video=@"$CLIP" \
    -F caption="$VCAP" "$API/sendVideo" >/dev/null
fi
fi

# Tidy old snapshots; print the caption for the calling agent/CLI.
find "$OJOGATO_HOME/frames" -name 'snap-*.jpg' -mmin +120 -delete 2>/dev/null
echo "$CAP"
[ -n "$RECAP_LINE" ] && echo "$RECAP_LINE"
exit 0

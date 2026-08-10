#!/bin/bash
# Status report -> Telegram: live snapshot photo + activity caption + ~9s last-movement clip; prints the caption.
# Called by `ojogato report`, the OpenClaw skill, or digest cron jobs. Usage: report.sh [now|digest]
#
# Sends via the plain Telegram Bot API (curl) using OJOGATO_TELEGRAM_TOKEN/CHAT — no
# agent framework in the loop. Last-movement evidence is clip.sh's clip, never a
# guessed still (still-selection caught the empty aftermath frame; clips replaced it).
MODE=${1:-now}
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

# Motion-based activity summary (6h and 12h windows).
S6=$("$BIN/motion-stats.sh" 6); S12=$("$BIN/motion-stats.sh" 12)
LMM=$(echo "$S6" | grep -oE 'LAST_MOTION_MIN=[0-9]+' | cut -d= -f2); LMM=${LMM:-9999}
MF6=$(echo "$S6" | grep -oE 'MOTION_FRAMES_LAST_6H=[0-9]+' | cut -d= -f2)
MF12=$(echo "$S12" | grep -oE 'MOTION_FRAMES_LAST_12H=[0-9]+' | cut -d= -f2)
if [ "$LMM" -ge 9999 ]; then LASTSEEN="no motion recorded yet"
elif [ "$LMM" -lt 60 ]; then LASTSEEN="last activity ${LMM} min ago"
else LASTSEEN="last activity $((LMM/60))h $((LMM%60))m ago"; fi

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
CAP="$LEAD: ${LASTSEEN}. Activity — ${MF6} motion moments last 6h, ${MF12} last 12h."
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

# Short clip of the last real movement (shows the subject, not a guessed still).
# The timestamp comes from clip.sh's lag-corrected event time, NOT the newest motion
# frame's filename — frame filenames trail the real event by ~6s (see clip.sh), so the
# old caption named a moment several seconds after the subject had already left.
CLIP=$("$BIN/clip.sh" 2>/dev/null)
META="$OJOGATO_HOME/frames/lastmove.meta"
CT=""; CLIP_YAVG=""
if [ -f "$META" ]; then
  CT=$(grep -oE 'CLIP_EVENT_HHMM=.*' "$META" | cut -d= -f2)
  CLIP_YAVG=$(grep -oE 'CLIP_YAVG=[0-9.]*' "$META" | cut -d= -f2)
fi
if [ -z "$CT" ]; then
  LM=$(ls -t "$OJOGATO_HOME/motionframes"/*.jpg 2>/dev/null | head -1)
  if [ -n "$LM" ]; then b=$(basename "$LM"); CT="${b:9:2}:${b:11:2}"; fi
fi
if [ -n "$CLIP" ] && [ -s "$CLIP" ]; then
  VCAP="🎥 Last movement — ${CT}"
  # No IR: below the dark threshold nothing in the clip is actually visible, so say so
  # rather than shipping a black video that reads as a camera fault.
  if [ -n "$CLIP_YAVG" ] && awk "BEGIN{exit !($CLIP_YAVG < ${OJOGATO_DARK_YAVG:-16})}"; then
    VCAP="$VCAP
🌑 Room was dark — nothing is visible in this clip. Leave a light on for usable night footage."
  fi
  curl -s -F chat_id="$OJOGATO_TELEGRAM_CHAT" -F video=@"$CLIP" \
    -F caption="$VCAP" "$API/sendVideo" >/dev/null
fi

# Tidy old snapshots; print the caption for the calling agent/CLI.
find "$OJOGATO_HOME/frames" -name 'snap-*.jpg' -mmin +120 -delete 2>/dev/null
echo "$CAP"

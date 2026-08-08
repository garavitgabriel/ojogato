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

if [ "$MODE" = "digest" ]; then LEAD="$EMOJI Digest on ${SUBJECT} ($(date '+%a %H:%M'))"
else LEAD="$EMOJI Checking on ${SUBJECT} ($(date '+%H:%M'))"; fi
CAP="$LEAD: ${LASTSEEN}. Activity — ${MF6} motion moments last 6h, ${MF12} last 12h."
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
LM=$(ls -t "$OJOGATO_HOME/motionframes"/*.jpg 2>/dev/null | head -1)
CT=""; if [ -n "$LM" ]; then b=$(basename "$LM"); CT="${b:9:2}:${b:11:2}"; fi
CLIP=$("$BIN/clip.sh" 2>/dev/null)
if [ -n "$CLIP" ] && [ -s "$CLIP" ]; then
  curl -s -F chat_id="$OJOGATO_TELEGRAM_CHAT" -F video=@"$CLIP" \
    -F caption="🎥 Last movement — ${CT}" "$API/sendVideo" >/dev/null
fi

# Tidy old snapshots; print the caption for the calling agent/CLI.
find "$OJOGATO_HOME/frames" -name 'snap-*.jpg' -mmin +120 -delete 2>/dev/null
echo "$CAP"

#!/bin/bash
# Watchdog: checks stream/recorder/motion/disk health and alerts via the Telegram Bot API when something is wrong.
# Runs under launchd as com.ojogato.heartbeat (StartInterval 1800) — deliberately OUTSIDE any agent framework.
#
# Behavior contract:
#  - Respects ~/.ojogato/PAUSED (silent while paused).
#  - Rate-limited to one alert per 3h so a broken stack doesn't spam.
#  - No-motion alarm only inside the daytime window (OJOGATO_DAY_START..OJOGATO_DAY_END),
#    threshold OJOGATO_NO_MOTION_HOURS.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

STATE="$OJOGATO_HOME/logs/heartbeat.last-alert"
REC="$OJOGATO_HOME/recordings"
CHECKS="$OJOGATO_HOME/checks/checks.jsonl"

[ -f "$OJOGATO_HOME/PAUSED" ] && exit 0

DAY_START="${OJOGATO_DAY_START:-8}"
DAY_END="${OJOGATO_DAY_END:-23}"
NO_MOTION_MIN=$(( ${OJOGATO_NO_MOTION_HOURS:-6} * 60 ))
PROBLEMS=()

# 1) Live stream server up?
pgrep -x mediamtx >/dev/null || PROBLEMS+=("mediamtx (live stream) is not running")

# 2) Recorder producing fresh segments?
NEWEST=$(ls -t "$REC"/*.mp4 2>/dev/null | head -1)
if [ -z "$NEWEST" ]; then
  PROBLEMS+=("no recordings exist yet — camera capture never started (camera permission?)")
else
  AGE=$(( $(date +%s) - $(stat -f %m "$NEWEST") ))
  [ "$AGE" -gt 1800 ] && PROBLEMS+=("newest recording is $((AGE / 60)) min old — capture stalled")
fi

# 3) No-motion alarm (daytime only): frozen camera or genuinely inactive subject.
HOUR=$((10#$(date +%H)))
if [ "$HOUR" -ge "$DAY_START" ] && [ "$HOUR" -le "$DAY_END" ]; then
  LMM=$("$OJOGATO_HOME/bin/motion-stats.sh" 12 | grep -oE "LAST_MOTION_MIN=[0-9]+" | cut -d= -f2)
  [ -n "$LMM" ] && [ "$LMM" -lt 9999 ] && [ "$LMM" -gt "$NO_MOTION_MIN" ] && \
    PROBLEMS+=("no motion detected in $((LMM/60))h — ${OJOGATO_SUBJECT:-subject} inactive or camera frozen")
fi

# 4) Disk headroom.
FREE_GB=$(df -g /System/Volumes/Data | tail -1 | awk '{print $4}')
[ "$FREE_GB" -lt 3 ] && PROBLEMS+=("disk critically low: ${FREE_GB}GB free")

# 5) Optional: if an agent logs its checks to checks/checks.jsonl, alert when it goes quiet.
if [ -f "$CHECKS" ] && [ "$HOUR" -ge 11 ] && [ "$HOUR" -le "$DAY_END" ]; then
  CAGE=$(( $(date +%s) - $(stat -f %m "$CHECKS") ))
  [ "$CAGE" -gt 14400 ] && PROBLEMS+=("no agent check logged in $((CAGE / 3600))h — companion agent may be wedged")
fi

[ ${#PROBLEMS[@]} -eq 0 ] && exit 0

# Rate limit: one alert per 3h.
LAST=0; [ -f "$STATE" ] && LAST=$(cat "$STATE")
NOW=$(date +%s)
[ $((NOW - LAST)) -lt 10800 ] && exit 0
mkdir -p "$OJOGATO_HOME/logs"
echo "$NOW" > "$STATE"

MSG="⚠️ [Ojo Gato watchdog — automated] issue on $(hostname -s):
$(printf ' • %s\n' "${PROBLEMS[@]}")"

if [ -z "${OJOGATO_TELEGRAM_TOKEN}" ] || [ -z "${OJOGATO_TELEGRAM_CHAT}" ]; then
  echo "heartbeat.sh: Telegram not configured — $MSG" >&2
  exit 0
fi
curl -s -X POST "https://api.telegram.org/bot${OJOGATO_TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="$OJOGATO_TELEGRAM_CHAT" --data-urlencode text="$MSG" >/dev/null

#!/bin/bash
# Supervisor: keeps the lighting profile current, restarts a wedged detector, and alerts via the
# Telegram Bot API when something is wrong. Runs under launchd as com.ojogato.heartbeat
# (StartInterval 300) — deliberately OUTSIDE any agent framework.
#
# Behavior contract:
#  - Respects ~/.ojogato/PAUSED (silent and inert while paused).
#  - Rate-limited to one alert per 3h so a broken stack doesn't spam.
#  - No-motion alarm only inside the daytime window (OJOGATO_DAY_START..OJOGATO_DAY_END),
#    threshold OJOGATO_NO_MOTION_HOURS.
#  - Repairs what it can repair, then reports having done it — it does not merely complain.
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

# 0) Keep the day/night motion profile matched to the actual light level. Cheap (reads the
#    detector's existing liveness frame) and a no-op unless the regime crossed a threshold.
[ -x "$OJOGATO_HOME/bin/motion-profile.sh" ] && "$OJOGATO_HOME/bin/motion-profile.sh" >/dev/null 2>&1

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

# 2b) Detector wedged? A stalled detector and a quiet room both produce zero motion frames,
#     so "no frames" cannot distinguish them — that ambiguity hid a 12h45m outage on
#     2026-08-10, where ffmpeg kept decoding while its filter graph emitted nothing.
#     detector-alive.jpg is written unconditionally every OJOGATO_DETECTOR_ALIVE_SEC, so a
#     stale mtime means the pipeline is dead regardless of what the room is doing. Restart
#     it here rather than waiting for a human: a blind camera is worth more noise than a
#     restart. Rate-limited so a stream that cannot come up doesn't get kicked in a loop.
ALIVE_IMG="$OJOGATO_HOME/frames/detector-alive.jpg"
ALIVE_SEC="${OJOGATO_DETECTOR_ALIVE_SEC:-30}"
STALL_SEC="${OJOGATO_DETECTOR_STALL_SEC:-$(( ALIVE_SEC * 6 ))}"
KICK_STATE="$OJOGATO_HOME/logs/detector.last-kick"
# Only meaningful once the installed detector actually writes the liveness frame.
if grep -q 'detector-alive' "$OJOGATO_HOME/bin/motion-run.sh" 2>/dev/null; then
  if [ -s "$ALIVE_IMG" ]; then
    ALIVE_AGE=$(( $(date +%s) - $(stat -f %m "$ALIVE_IMG") ))
  else
    ALIVE_AGE=$(( STALL_SEC + 1 ))
  fi
  if [ "$ALIVE_AGE" -gt "$STALL_SEC" ]; then
    LASTKICK=0; [ -f "$KICK_STATE" ] && LASTKICK=$(cat "$KICK_STATE")
    if [ $(( $(date +%s) - LASTKICK )) -ge 900 ]; then
      date +%s > "$KICK_STATE"
      launchctl kickstart -k "gui/$(id -u)/com.ojogato.motion" 2>/dev/null
      echo "$(date '+%Y-%m-%d %H:%M:%S') detector stalled (${ALIVE_AGE}s since last frame) — restarted" \
        >> "$OJOGATO_HOME/logs/profile.log"
      PROBLEMS+=("motion detector had stalled (${ALIVE_AGE}s with no frames) — restarted it automatically")
    fi
  fi
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

MSG="⚠️ [Ojo de Gato watchdog — automated] issue on $(hostname -s):
$(printf ' • %s\n' "${PROBLEMS[@]}")"

if [ -z "${OJOGATO_TELEGRAM_TOKEN}" ] || [ -z "${OJOGATO_TELEGRAM_CHAT}" ]; then
  echo "heartbeat.sh: Telegram not configured — $MSG" >&2
  exit 0
fi
curl -s -X POST "https://api.telegram.org/bot${OJOGATO_TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="$OJOGATO_TELEGRAM_CHAT" --data-urlencode text="$MSG" >/dev/null

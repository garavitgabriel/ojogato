#!/bin/bash
# Motion summary: prints LAST_MOTION_MIN=<minutes since last motion BURST> plus raw counters.
# Called by report.sh and heartbeat.sh (also handy interactively). Usage: motion-stats.sh [window_hours=6]
#
# Burst-aware: LAST_MOTION_MIN anchors on the newest cluster of >= OJOGATO_BURST_MIN
# frames <= OJOGATO_BURST_GAP seconds apart — the same rule clip.sh uses — so an
# isolated auto-exposure false positive can't refresh "last motion" (that's how the
# report kept claiming fresh movement over an empty room, 2026-08-09).
# LAST_FRAME_MIN is the raw newest-frame age, kept for debugging the detector itself.
#
# LAST_MOTION_MIN=9999 means no qualifying burst (LAST_FRAME_MIN=9999: no frames at all).
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

DIR="$OJOGATO_HOME/motionframes"
WIN_H=${1:-6}
GAP="${OJOGATO_BURST_GAP:-4}"
BMIN="${OJOGATO_BURST_MIN:-2}"
NOW=$(date +%s)

NEW=$(ls -t "$DIR"/*.jpg 2>/dev/null | head -1)
if [ -n "$NEW" ]; then FRAME_MIN=$(( (NOW - $(stat -f %m "$NEW")) / 60 )); else FRAME_MIN=9999; fi

# Newest burst end among the last 200 frames (oldest -> newest), same clustering as clip.sh.
TIMES=$(ls -t "$DIR"/*.jpg 2>/dev/null | head -200 | while read -r f; do stat -f %m "$f"; done | sort -n)
B_END=""; C_END=""; C_N=0; PREV=0
for t in $TIMES; do
  if [ "$PREV" -ne 0 ] && [ $(( t - PREV )) -le "$GAP" ]; then
    C_END=$t; C_N=$(( C_N + 1 ))
  else
    C_END=$t; C_N=1
  fi
  if [ "$C_N" -ge "$BMIN" ]; then B_END=$C_END; fi
  PREV=$t
done
if [ -n "$B_END" ]; then MIN=$(( (NOW - B_END) / 60 )); else MIN=9999; fi

EV=$(find "$DIR" -name '*.jpg' -mmin -$((WIN_H*60)) 2>/dev/null | wc -l | tr -d ' ')
echo "LAST_MOTION_MIN=$MIN MOTION_FRAMES_LAST_${WIN_H}H=$EV LAST_FRAME_MIN=$FRAME_MIN"

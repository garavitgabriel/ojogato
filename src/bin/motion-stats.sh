#!/bin/bash
# Motion summary: prints LAST_MOTION_MIN=<minutes since newest motion frame> and MOTION_FRAMES_LAST_<N>H=<count>.
# Called by report.sh and heartbeat.sh (also handy interactively). Usage: motion-stats.sh [window_hours=6]
#
# LAST_MOTION_MIN=9999 means no motion frame has ever been recorded.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

DIR="$OJOGATO_HOME/motionframes"
WIN_H=${1:-6}
NOW=$(date +%s)
NEW=$(ls -t "$DIR"/*.jpg 2>/dev/null | head -1)
if [ -n "$NEW" ]; then MIN=$(( (NOW - $(stat -f %m "$NEW")) / 60 )); else MIN=9999; fi
EV=$(find "$DIR" -name '*.jpg' -mmin -$((WIN_H*60)) 2>/dev/null | wc -l | tr -d ' ')
echo "LAST_MOTION_MIN=$MIN MOTION_FRAMES_LAST_${WIN_H}H=$EV"

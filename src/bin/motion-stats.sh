#!/bin/bash
# Motion summary. Called by report.sh and heartbeat.sh (also handy interactively).
# Usage: motion-stats.sh [window_hours=6]
#
# Prints, space-separated:
#   LAST_MOTION_MIN=<minutes since the last VERIFIED event ended>
#   MOTION_EVENTS_LAST_<N>H=<verified events in the window>
#   MOTION_FRAMES_LAST_<N>H=<raw candidate frames in the window — diagnostics only>
#   NOISE_EVENTS_LAST_<N>H=<events checked and found to contain no subject>
#   LAST_FRAME_MIN=<raw newest-frame age, for debugging the detector itself>
#   VISION=on|off|stale
#
# LAST_MOTION_MIN=9999 means no verified event in the window (LAST_FRAME_MIN=9999: no
# frames at all).
#
# "Verified" means events.sh found a cat, dog or person in at least one frame of the
# event. That is a deliberate change of meaning from the frame counting this script used
# to do, and the reason is that frame counts had become fiction: on 2026-08-15 the 6h
# count read 243 while the room had been empty for hours, because the webcam's
# auto-exposure hunting kept tripping mpdecimate. The old burst heuristic (>=2 frames
# within 4s) was an attempt to filter that statistically, and it could not — flicker
# produces qualifying pairs too, which is exactly what the "last movement" clip sent to
# the phone had been anchored on.
#
# MOTION_FRAMES_LAST_<N>H is still emitted, because it is the honest measure of how noisy
# the detector is and the gap between it and MOTION_EVENTS is the thing to watch when
# tuning. It is simply no longer what gets reported to a human as "activity".
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

BIN="$OJOGATO_HOME/bin"
DIR="$OJOGATO_HOME/motionframes"
WIN_H=${1:-6}
NOW=$(date +%s)

NEW=$(ls -t "$DIR"/*.jpg 2>/dev/null | head -1)
if [ -n "$NEW" ]; then FRAME_MIN=$(( (NOW - $(stat -f %m "$NEW")) / 60 )); else FRAME_MIN=9999; fi
FRAMES=$(find "$DIR" -name '*.jpg' -mmin -$((WIN_H*60)) 2>/dev/null | wc -l | tr -d ' ')

# Is the verifier keeping up? A verifier that died must not read as "quiet room" — that is
# the same ambiguity one layer up which hid a 12h45m detector outage on 2026-08-10.
VISION_STATE="off"
if [ "${OJOGATO_VISION_ENABLED:-1}" != "0" ] && [ -x "$BIN/events.sh" ]; then
  ALIVE="$OJOGATO_HOME/vision/verifier-alive"
  STALE_SEC="${OJOGATO_VISION_STALL_SEC:-300}"
  if [ -s "$ALIVE" ] && [ $(( NOW - $(cat "$ALIVE" 2>/dev/null || echo 0) )) -le "$STALE_SEC" ]; then
    VISION_STATE="on"
  else
    VISION_STATE="stale"
  fi
fi

NEVENTS=""; NNOISE=""
if [ "$VISION_STATE" = "on" ]; then
  EVENTS=$("$BIN/events.sh" --hours "$WIN_H" 2>/dev/null)
  NEVENTS=$(printf '%s\n' "$EVENTS" | awk -F'\t' '$5=="pet"||$5=="person"' | grep -c . | tr -d ' ')
  NNOISE=$(printf '%s\n'  "$EVENTS" | awk -F'\t' '$5=="none"'              | grep -c . | tr -d ' ')
  LAST_END=$(printf '%s\n' "$EVENTS" | awk -F'\t' '$5=="pet"||$5=="person"{e=$2} END{if(e)print e}')
  if [ -n "$LAST_END" ]; then MIN=$(( (NOW - LAST_END) / 60 )); else MIN=9999; fi
else
  # Fallback while the verifier is off or stale: the pre-vision burst heuristic, so the
  # watchdog and the reports keep working. Callers surface VISION= so a human can tell
  # which regime produced the numbers.
  GAP="${OJOGATO_BURST_GAP:-4}"
  BMIN="${OJOGATO_BURST_MIN:-2}"
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
fi

OUT="LAST_MOTION_MIN=$MIN"
[ -n "$NEVENTS" ] && OUT="$OUT MOTION_EVENTS_LAST_${WIN_H}H=$NEVENTS"
OUT="$OUT MOTION_FRAMES_LAST_${WIN_H}H=$FRAMES"
[ -n "$NNOISE" ] && OUT="$OUT NOISE_EVENTS_LAST_${WIN_H}H=$NNOISE"
echo "$OUT LAST_FRAME_MIN=$FRAME_MIN VISION=$VISION_STATE"

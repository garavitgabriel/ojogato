#!/bin/bash
# Fixture stub: recap.sh [--hours N] [--max N] [--no-send] [--json] (contract 5).
# Send mode never sends: it logs the call to OJOGATO_FIXTURE_LOG and prints a caption.
source "$(dirname "$0")/_fixture.sh"
SEND=1; JSON=0; ARGS="$*"
while [ $# -gt 0 ]; do case "$1" in --no-send) SEND=0; shift ;; --json) JSON=1; shift ;; --hours|--max) shift 2 ;; *) shift ;; esac; done
[ "$FX_MODE" = "error" ] && fx_fail 1 "recap failed (fixture)"
if [ "$SEND" = "1" ]; then fx_log "recap.sh $ARGS"; echo "🐱 Recap (fixture): 2 moments today. [not sent: fixture]"; exit 0; fi
if [ "$FX_MODE" = "empty" ]; then echo '{"path":null,"caption":"Nothing to recap today.","moments":[]}'; exit 0; fi
printf '{"path":"%s","caption":"🐱 Recap: 2 moments today","moments":[{"event_id":"%d","time_hhmm":"%s","verdict":"pet"},{"event_id":"%d","time_hhmm":"%s","verdict":"person"}]}\n' \
  "$FX_HOME/frames/recap-fixture.mp4" "$((FX_BASE-14400))" "$(date -r $((FX_BASE-14400)) +%H:%M)" "$((FX_BASE-900))" "$(date -r $((FX_BASE-900)) +%H:%M)"

#!/bin/bash
# Retention: deletes recordings older than OJOGATO_RETENTION_HOURS and caps the folder at OJOGATO_CAP_GB (oldest-first).
# Runs under launchd as com.ojogato.cleanup (StartInterval 1800).
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

REC="$OJOGATO_HOME/recordings"
RET_MIN=$(( ${OJOGATO_RETENTION_HOURS:-48} * 60 ))
CAP_KB=$(( ${OJOGATO_CAP_GB:-9} * 1024 * 1024 ))

# Age-based retention.
find "$REC" -name "*.mp4" -mmin +"$RET_MIN" -delete 2>/dev/null

# Size cap: drop oldest segments until under OJOGATO_CAP_GB, so the disk keeps headroom.
while [ "$(du -sk "$REC" 2>/dev/null | cut -f1)" -gt "$CAP_KB" ]; do
  OLD=$(ls -t "$REC"/*.mp4 2>/dev/null | tail -1)
  [ -z "$OLD" ] && break
  rm -f "$OLD"
done

# Motion frames follow the same age retention (tiny jpgs, but unbounded otherwise).
find "$OJOGATO_HOME/motionframes" -name "*.jpg" -mmin +"$RET_MIN" -delete 2>/dev/null

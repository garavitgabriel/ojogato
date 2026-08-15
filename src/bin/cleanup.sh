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

# Vision verdicts are append-only and keyed by frame basename, so they outlive the frames
# they describe and would grow forever. Drop rows whose frame is past retention — once the
# JPEG is gone nothing can re-derive or re-check that verdict anyway. Rewritten through a
# temp file and mv so a consumer reading the cache mid-prune sees one whole file or the
# other, never a truncated one.
VERDICTS="$OJOGATO_HOME/vision/verdicts.tsv"
if [ -s "$VERDICTS" ]; then
  CUTOFF=$(( $(date +%s) - RET_MIN * 60 ))
  TMP="$VERDICTS.tmp.$$"
  if awk -F'\t' -v c="$CUTOFF" '$1+0 >= c' "$VERDICTS" > "$TMP" 2>/dev/null; then
    mv -f "$TMP" "$VERDICTS"
  else
    rm -f "$TMP"
  fi
fi

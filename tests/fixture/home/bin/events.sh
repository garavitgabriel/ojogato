#!/bin/bash
# Fixture stub: events.sh --json [--hours N] [--real-only] [--since E] [--event ID] (contract 3).
# NDJSON (one object per line), like the real script. Event times are relative to now.
source "$(dirname "$0")/_fixture.sh"
HOURS=24; REAL=0; SINCE=""; EVENT=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;; --since) SINCE="$2"; shift 2 ;; --event) EVENT="$2"; shift 2 ;;
    --real-only) REAL=1; shift ;; --json) JSON=1; shift ;; *) shift ;;
  esac
done
[ "$JSON" = "1" ] || { echo "fixture events.sh only supports --json" >&2; exit 2; }
[ "$FX_MODE" = "error" ] && fx_fail 1 "events failed (fixture)"
# start end frames subject_frames verdict score best_frame
ROWS="$((FX_BASE-14400)) $((FX_BASE-14340)) 9 4 pet 0.912 20261015-091500
$((FX_BASE-7200)) $((FX_BASE-7170)) 6 0 none 0.000 -
$((FX_BASE-900)) $((FX_BASE-860)) 7 3 person 0.774 20261015-091500"
[ "$FX_MODE" = "empty" ] && ROWS=""
FOUND=0
CUTOFF=$((FX_NOW - HOURS*3600))
while read -r st en nf ns vd sc bf; do
  [ -n "$st" ] || continue
  if [ -n "$EVENT" ]; then [ "$st" = "$EVENT" ] || continue
  else
    [ "$en" -ge "$CUTOFF" ] || continue
    [ "$REAL" = "1" ] && [ "$vd" = "none" ] && continue
    [ -n "$SINCE" ] && [ "$en" -le "$SINCE" ] && continue
  fi
  [ "$bf" = "-" ] && { bf=""; be=0; sf=0; sl=0; } || { be=$((st+20)); sf=$((st+10)); sl=$((en-5)); }
  printf '{"start":%d,"end":%d,"frames":%d,"subject_frames":%d,"verdict":"%s","score":%s,"best_epoch":%d,"best_frame":"%s","subject_first":%d,"subject_last":%d,"event_id":"%s"}\n' \
    "$st" "$en" "$nf" "$ns" "$vd" "$sc" "$be" "$bf" "$sf" "$sl" "$st"
  FOUND=1
done <<ROWS_EOF
$ROWS
ROWS_EOF
[ -n "$EVENT" ] && [ "$FOUND" = "0" ] && fx_fail 3 "no such event"
exit 0

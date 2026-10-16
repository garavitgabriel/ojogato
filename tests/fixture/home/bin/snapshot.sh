#!/bin/bash
# Fixture stub: snapshot.sh [--max-width N] (contract 2). error mode = stream down (exit 2).
source "$(dirname "$0")/_fixture.sh"
W=768
while [ $# -gt 0 ]; do case "$1" in --max-width) W="$2"; shift 2 ;; *) shift ;; esac; done
[ "$FX_MODE" = "error" ] && fx_fail 2 "stream down"
DARK=false; LUMA=43.2; [ "$FX_MODE" = "empty" ] && { DARK=true; LUMA=7.9; }
printf '{"path":"%s","taken_at":%d,"width":96,"height":64,"luma":%s,"dark":%s}\n' \
  "$FX_HOME/frames/snapshot.jpg" "$FX_NOW" "$LUMA" "$DARK"

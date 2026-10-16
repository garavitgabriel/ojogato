#!/bin/bash
# Fixture stub: clip.sh --json (contract 4). Plain mode prints the path, like the real one.
source "$(dirname "$0")/_fixture.sh"
[ "$FX_MODE" = "error" ] && fx_fail 1 "clip failed (fixture)"
if [ "$1" != "--json" ]; then [ "$FX_MODE" = "empty" ] || echo "$FX_HOME/frames/lastmove.mp4"; exit 0; fi
if [ "$FX_MODE" = "empty" ]; then
  echo '{"path":null,"event_id":null,"event_hhmm":null,"verdict":null,"duration_s":null,"luma":null,"dark":null}'
else
  printf '{"path":"%s","event_id":"%d","event_hhmm":"%s","verdict":"person","duration_s":9.0,"luma":43.2,"dark":false}\n' \
    "$FX_HOME/frames/lastmove.mp4" "$((FX_BASE-900))" "$(date -r $((FX_BASE-900)) +%H:%M)"
fi

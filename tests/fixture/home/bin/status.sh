#!/bin/bash
# Fixture stub: status.sh --json (contract 1).
source "$(dirname "$0")/_fixture.sh"
[ "$1" = "--json" ] || { echo "fixture status.sh only supports --json" >&2; exit 2; }
case "$FX_MODE" in
  error) fx_fail 1 "status failed (fixture)" ;;
  empty) printf '{"generated_at":%d,"paused":false,"vision":"on","last_seen_min":null,"sightings_6h":0,"sightings_12h":0,"raw_frames_6h":0,"raw_frames_12h":0,"detector_alive":true,"luma":41.5,"dark":false,"live_url":null,"subject":"the cats","pet_names":null}\n' "$FX_NOW" ;;
  *)     printf '{"generated_at":%d,"paused":false,"vision":"on","last_seen_min":12,"sightings_6h":2,"sightings_12h":5,"raw_frames_6h":140,"raw_frames_12h":310,"detector_alive":true,"luma":43.2,"dark":false,"live_url":"http://cam-mac.example.ts.net:8889/cam","subject":"the cats","pet_names":"Mochi, Nube"}\n' "$FX_NOW" ;;
esac

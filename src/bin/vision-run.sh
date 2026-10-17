#!/bin/bash
# Vision verifier: classifies each new motion frame and appends the verdict to the cache
# that events.sh reads. Runs under launchd as com.ojogato.vision (KeepAlive). If PAUSED,
# sleeps instead of exiting so KeepAlive doesn't thrash — same contract as motion-run.sh.
#
# This is the layer that turns "pixels changed" into "a subject was there". The detector
# stays exactly as sensitive as it was: it is a cheap proposer that cuts 86,400 frames a
# day down to a few thousand candidates, and a proposer is allowed to be wrong. Deciding
# what actually happened is this script's job, and it is a separate process on purpose —
# if it dies, the detector, the recorder and the live stream are untouched, and the
# reports fall back to raw frames (loudly, saying so) rather than going silent.
#
# Cost on the reference machine (2019 Intel MBP, no Neural Engine): ~65ms per frame for a
# confident full-frame hit, ~350ms when all six tiles are tried. At a few thousand
# candidate frames a day that is a couple of minutes of CPU spread across 24 hours.
#
# Hard-won details (do not "fix"):
#  - Frames are classified OLDEST FIRST. A backlog after a restart must not leave the most
#    recent minutes unverified while it grinds through yesterday, so the batch is capped
#    and the newest frames are picked up on the next pass, seconds later.
#  - The verdict cache is append-only and keyed by frame basename. Re-running is free and
#    idempotent; nothing is ever re-classified.
#  - Writes go through a lock file. Two overlapping passes (a slow batch plus launchd
#    restarting the job) would otherwise interleave half-written lines into the cache and
#    every consumer would silently mis-parse them.

OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

[ -f "$OJOGATO_HOME/PAUSED" ] && exec sleep 3600
[ "${OJOGATO_VISION_ENABLED:-1}" = "0" ] && exec sleep 3600

BIN="$OJOGATO_HOME/bin"
VISION="$BIN/ojogato-vision"
FRAMES="$OJOGATO_HOME/motionframes"
DIR="$OJOGATO_HOME/vision"
VERDICTS="$DIR/verdicts.tsv"
LOCK="$DIR/.lock"
ALIVE="$DIR/verifier-alive"

MIN="${OJOGATO_VISION_MIN_CONFIDENCE:-0.30}"
TILES="${OJOGATO_VISION_TILES:-3x2}"
BATCH="${OJOGATO_VISION_BATCH:-200}"
INTERVAL="${OJOGATO_VISION_INTERVAL:-5}"

mkdir -p "$DIR" "$FRAMES"
touch "$VERDICTS"

if [ ! -x "$VISION" ]; then
  echo "vision-run.sh: $VISION missing or not executable — run install.sh to build it" >&2
  # Sleep rather than exit: KeepAlive would otherwise spin on a machine where the Swift
  # build failed, and the rest of the stack is fine without us.
  exec sleep 3600
fi

while :; do
  if [ -f "$OJOGATO_HOME/PAUSED" ]; then sleep 60; continue; fi

  # Frames with no verdict yet, oldest first, capped at one batch.
  PENDING=$(ls "$FRAMES"/*.jpg 2>/dev/null | sort | awk -v v="$VERDICTS" '
    BEGIN { while ((getline l < v) > 0) { split(l, a, "\t"); seen[a[2]] = 1 } close(v) }
    { b = $0; sub(/.*\//, "", b); sub(/\.jpg$/, "", b); if (!(b in seen)) print }
  ' | head -n "$BATCH")

  if [ -n "$PENDING" ]; then
    # flock isn't on macOS; a mkdir lock is atomic on every filesystem we care about.
    if mkdir "$LOCK" 2>/dev/null; then
      trap 'rmdir "$LOCK" 2>/dev/null' EXIT
      printf '%s\n' "$PENDING" | "$VISION" --min "$MIN" --tiles "$TILES" - 2>/dev/null | \
      while IFS=$'\t' read -r path verdict score detail; do
        [ -n "$path" ] || continue
        b=$(basename "$path" .jpg)
        e=$(date -j -f "%Y%m%d-%H%M%S" "$b" +%s 2>/dev/null) || e=0
        printf '%s\t%s\t%s\t%s\t%s\n' "$e" "$b" "$verdict" "$score" "$detail" >> "$VERDICTS"
      done
      rmdir "$LOCK" 2>/dev/null
      trap - EXIT
    fi
  fi

  # Liveness, same idea as the detector's: a verifier that is wedged and a night with no
  # cats both leave the event list empty, and only this file tells them apart.
  date +%s > "$ALIVE.tmp" && mv -f "$ALIVE.tmp" "$ALIVE"  # atomic: readers never see it empty
  sleep "$INTERVAL"
done

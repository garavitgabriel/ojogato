#!/bin/bash
# Motion detector: continuous ffmpeg saves one timestamped jpg per moment of real change (mpdecimate).
# Runs under launchd as com.ojogato.motion (KeepAlive). If PAUSED, sleeps instead of exiting so KeepAlive doesn't thrash.
#
# Hard-won details (do not "fix"):
#  - mpdecimate hi/lo/frac come from config; hi=64*48 lo=64*24 frac=0.6 are the tuned daylight defaults.
#  - deflicker runs BEFORE mpdecimate: the webcam's auto-exposure steps shift global luma,
#    which spikes SAD at every high-contrast edge and fakes motion in an empty room
#    (validated against real recordings 2026-08-09 — storms of false frames tracked daylight,
#    not cats). deflicker normalizes frame brightness so only local change survives.
#    Set OJOGATO_MOTION_PREFILTER="null" to disable it.
#  - ffmpeg 9 renamed -vsync to -fps_mode; vfr keeps only the frames mpdecimate lets through.
#  - profile.env (written by motion-profile.sh) is sourced AFTER config.env and overrides the
#    thresholds for the current lighting regime. It is generated, never hand-edited.
#  - -use_wallclock_as_timestamps 1 is load-bearing, not cosmetic. The RTSP timestamps mediamtx
#    hands us are a 32-bit 90kHz clock that wraps roughly every 13h15m. A wrap looks to the `fps`
#    filter like time jumping backwards, and `fps` responds by dropping every frame until source
#    time catches up — which never happens. Observed 2026-08-10: the detector decoded happily for
#    12h45m while emitting zero frames. Stamping frames with wall clock makes the graph immune to
#    any input-timestamp discontinuity.
#  - The second output (detector-alive.jpg) exists so a watchdog can tell "quiet room" apart from
#    "wedged pipeline" — both look like zero motion frames. It is written unconditionally, before
#    mpdecimate, so a fresh mtime proves decode + filter + mux are all still moving.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"
[ -f "$OJOGATO_HOME/profile.env" ] && source "$OJOGATO_HOME/profile.env"

[ -f "$OJOGATO_HOME/PAUSED" ] && exec sleep 3600

FFMPEG="$OJOGATO_HOME/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"

ALIVE_SEC="${OJOGATO_DETECTOR_ALIVE_SEC:-30}"

mkdir -p "$OJOGATO_HOME/motionframes" "$OJOGATO_HOME/frames"
# -y and -nostdin are both load-bearing under launchd. detector-alive.jpg survives across
# restarts, so without -y ffmpeg asks "Overwrite? [y/N]" on every start after the first and
# exits — which takes the whole detector down while a first-run test passes cleanly. -nostdin
# makes sure no future prompt can ever block a daemon that has no terminal to answer from.
exec "$FFMPEG" -hide_banner -loglevel error -nostdin -y \
  -use_wallclock_as_timestamps 1 \
  -rtsp_transport tcp -i rtsp://127.0.0.1:8554/cam -an \
  -vf "fps=${OJOGATO_MOTION_FPS:-1},${OJOGATO_MOTION_PREFILTER:-deflicker=size=5:mode=am},mpdecimate=hi=64*${OJOGATO_MOTION_HI:-48}:lo=64*${OJOGATO_MOTION_LO:-24}:frac=${OJOGATO_MOTION_FRAC:-0.6}" \
  -fps_mode vfr \
  -f image2 -strftime 1 "$OJOGATO_HOME/motionframes/%Y%m%d-%H%M%S.jpg" \
  -vf "fps=1/${ALIVE_SEC}" -fps_mode vfr -q:v 6 \
  -f image2 -update 1 "$OJOGATO_HOME/frames/detector-alive.jpg"

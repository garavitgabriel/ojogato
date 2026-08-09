#!/bin/bash
# Motion detector: continuous ffmpeg saves one timestamped jpg per moment of real change (mpdecimate).
# Runs under launchd as com.ojogato.motion (KeepAlive). If PAUSED, sleeps instead of exiting so KeepAlive doesn't thrash.
#
# Hard-won details (do not "fix"):
#  - mpdecimate hi/lo/frac come from config; hi=64*48 lo=64*24 frac=0.6 are the tuned defaults.
#  - deflicker runs BEFORE mpdecimate: the webcam's auto-exposure steps shift global luma,
#    which spikes SAD at every high-contrast edge and fakes motion in an empty room
#    (validated against real recordings 2026-08-09 — storms of false frames tracked daylight,
#    not cats). deflicker normalizes frame brightness so only local change survives.
#    Set OJOGATO_MOTION_PREFILTER="null" to disable it.
#  - ffmpeg 9 renamed -vsync to -fps_mode; vfr keeps only the frames mpdecimate lets through.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

[ -f "$OJOGATO_HOME/PAUSED" ] && exec sleep 3600

FFMPEG="$OJOGATO_HOME/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"

mkdir -p "$OJOGATO_HOME/motionframes"
exec "$FFMPEG" -hide_banner -loglevel error \
  -rtsp_transport tcp -i rtsp://127.0.0.1:8554/cam -an \
  -vf "fps=${OJOGATO_MOTION_FPS:-1},${OJOGATO_MOTION_PREFILTER:-deflicker=size=5:mode=am},mpdecimate=hi=64*${OJOGATO_MOTION_HI:-48}:lo=64*${OJOGATO_MOTION_LO:-24}:frac=${OJOGATO_MOTION_FRAC:-0.6}" \
  -fps_mode vfr \
  -f image2 -strftime 1 "$OJOGATO_HOME/motionframes/%Y%m%d-%H%M%S.jpg"

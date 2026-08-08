#!/bin/bash
# Motion detector: continuous ffmpeg saves one timestamped jpg per moment of real change (mpdecimate).
# Runs under launchd as com.ojogato.motion (KeepAlive). If PAUSED, sleeps instead of exiting so KeepAlive doesn't thrash.
#
# Hard-won details (do not "fix"):
#  - mpdecimate hi/lo/frac come from config; hi=64*28 lo=64*14 frac=0.4 are the tuned defaults.
#  - ffmpeg 9 renamed -vsync to -fps_mode; vfr keeps only the frames mpdecimate lets through.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

[ -f "$OJOGATO_HOME/PAUSED" ] && exec sleep 3600

FFMPEG="$OJOGATO_HOME/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"

mkdir -p "$OJOGATO_HOME/motionframes"
exec "$FFMPEG" -hide_banner -loglevel error \
  -rtsp_transport tcp -i rtsp://127.0.0.1:8554/cam -an \
  -vf "fps=${OJOGATO_MOTION_FPS:-1},mpdecimate=hi=64*${OJOGATO_MOTION_HI:-28}:lo=64*${OJOGATO_MOTION_LO:-14}:frac=${OJOGATO_MOTION_FRAC:-0.4}" \
  -fps_mode vfr \
  -f image2 -strftime 1 "$OJOGATO_HOME/motionframes/%Y%m%d-%H%M%S.jpg"

#!/bin/bash
# Camera -> loopback RTSP publisher: avfoundation capture, hardware h264, publishes rtsp://127.0.0.1:8554/cam.
# Runs under launchd as com.ojogato.capture (KeepAlive).
#
# Hard-won details (do not "fix"):
#  - format=yuv420p lives in the FILTER (-vf), never as an input pixel format —
#    avfoundation rejects yuv420p as an input format on many cameras.
#  - Capture at the camera's native 30fps, then downsample with fps=N in the filter;
#    asking avfoundation for a low framerate directly fails on most devices.
#  - Prefers the ffmpeg inside OjoGato.app so macOS TCC attributes the camera
#    access to the Ojo Gato bundle (the permission the user granted at setup).
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

FFMPEG="$OJOGATO_HOME/OjoGato.app/Contents/MacOS/ojogato-capture"
[ -x "$FFMPEG" ] || FFMPEG="$OJOGATO_HOME/bin/ffmpeg"

RES="${OJOGATO_RES:-1280x720}"
FPS="${OJOGATO_STREAM_FPS:-12}"
BR="${OJOGATO_BITRATE:-500k}"
# maxrate = 1.4x bitrate (reference: 500k -> 700k); GOP = 2s at the stream fps.
case "$BR" in
  *k) MAXRATE="$(( ${BR%k} * 7 / 5 ))k" ;;
  *)  MAXRATE="$BR" ;;
esac
GOP=$(( FPS * 2 ))

mkdir -p "$OJOGATO_HOME/logs"
exec "$FFMPEG" -hide_banner -loglevel info \
  -f avfoundation -framerate 30 -video_size "$RES" -i "${OJOGATO_DEVICE:-0}" \
  -vf "fps=${FPS},format=yuv420p" \
  -c:v h264_videotoolbox -b:v "$BR" -maxrate "$MAXRATE" -g "$GOP" \
  -an -f rtsp rtsp://127.0.0.1:8554/cam 2>>"$OJOGATO_HOME/logs/capture.err"

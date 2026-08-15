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
#    access to the Ojo de Gato bundle (the permission the user granted at setup).
#
#  - The input is a device NAME, never an index, and this script never enumerates.
#    Two separate reasons, both learned the hard way on 2026-08-15:
#
#    (a) Indices are positional over whatever devices exist at that moment, and macOS
#        lists "Capture screen N" as a video device alongside cameras. When the built-in
#        camera dropped off the bus, the configured index 0 silently became THE SCREEN.
#        Nothing was captured only because the bundle holds no Screen Recording grant —
#        luck, not design. A monitor one permission away from streaming its owner's
#        desktop to Telegram is not acceptable.
#
#    (b) `-list_devices` cannot be used to resolve the name here, because enumeration and
#        capture have OPPOSITE permission behaviour. From an SSH shell, enumeration
#        answers instantly but opening the camera blocks forever (no TCC grant in that
#        context). Under launchd — where this actually runs, and where opening the camera
#        works — enumeration blocks instead, because the device list includes screen-capture
#        devices and that check has nobody to answer it. A probe that is correct in the
#        shell you test it from is exactly wrong in the context it ships to.
#
#    So: pass the name straight to ffmpeg. avfoundation matches devices by name, a missing
#    camera fails fast and loudly instead of hanging, and no screen device can ever be
#    selected. To find your camera's name, run this from a terminal (not over SSH):
#      ~/.ojogato/OjoGato.app/Contents/MacOS/ojogato-capture -f avfoundation -list_devices true -i ""
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

FFMPEG="$OJOGATO_HOME/OjoGato.app/Contents/MacOS/ojogato-capture"
[ -x "$FFMPEG" ] || FFMPEG="$OJOGATO_HOME/bin/ffmpeg"

LOG="$OJOGATO_HOME/logs/capture.err"
mkdir -p "$OJOGATO_HOME/logs"

RES="${OJOGATO_RES:-1280x720}"
FPS="${OJOGATO_STREAM_FPS:-12}"
BR="${OJOGATO_BITRATE:-500k}"
# maxrate = 1.4x bitrate (reference: 500k -> 700k); GOP = 2s at the stream fps.
case "$BR" in
  *k) MAXRATE="$(( ${BR%k} * 7 / 5 ))k" ;;
  *)  MAXRATE="$BR" ;;
esac
GOP=$(( FPS * 2 ))

# Default is the built-in Mac camera; override for a USB cam. Deliberately NOT
# OJOGATO_DEVICE — a bare index is the failure mode described above, and silently
# honouring an old numeric config would reintroduce it on every existing install.
DEV="${OJOGATO_DEVICE_NAME:-FaceTime HD Camera}"

case "$DEV" in
  "Capture screen"*|[0-9]|[0-9][0-9])
    echo "$(date '+%Y-%m-%d %H:%M:%S') capture-stream.sh: REFUSING to capture '$DEV'. OJOGATO_DEVICE_NAME must be a camera NAME, not an index or a screen-capture device — an index can resolve to the screen when the camera drops off the bus. Set it to e.g. 'FaceTime HD Camera'." >> "$LOG"
    exec sleep 300
    ;;
esac

echo "$(date '+%Y-%m-%d %H:%M:%S') capture-stream.sh: opening camera by name: '$DEV'" >> "$LOG"

exec "$FFMPEG" -hide_banner -loglevel info \
  -f avfoundation -framerate 30 -video_size "$RES" -i "$DEV" \
  -vf "fps=${FPS},format=yuv420p" \
  -c:v h264_videotoolbox -b:v "$BR" -maxrate "$MAXRATE" -g "$GOP" \
  -an -f rtsp rtsp://127.0.0.1:8554/cam 2>>"$LOG"

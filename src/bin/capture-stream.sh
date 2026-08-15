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
#  - The input is resolved to a device INDEX BY NAME on every start, never taken from
#    config as a bare number. avfoundation indices are positional over whatever devices
#    exist at that moment, and macOS also exposes "Capture screen N" as a video device in
#    the same list. On 2026-08-15 the built-in camera dropped off the bus entirely and
#    index 0 — the configured value — silently became *the screen*. Nothing was captured
#    only because the bundle has no Screen Recording grant; that is luck, not design, and
#    a monitor that can be one permission away from streaming its owner's desktop to
#    Telegram is not acceptable. A missing camera must be a loud stop, never a fallback.
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

# ---------------------------------------------------------------- device resolution
# Enumeration itself can hang. When the CoreMediaIO assistants wedge, `-list_devices`
# stops returning at all rather than returning an empty list (observed 2026-08-15: the
# probe sat at 0% CPU indefinitely), so an unbounded call here would reintroduce the exact
# silent hang this guard exists to replace. Bounded, and a timeout is reported as its own
# distinct state — "enumeration hung" is a different diagnosis from "no camera present".
DEVLIST_TIMEOUT="${OJOGATO_DEVLIST_TIMEOUT:-20}"
PROBE_OUT="$OJOGATO_HOME/logs/.devlist.$$"

probe_devices() { # -> 0 ok, 124 timed out
  "$FFMPEG" -hide_banner -f avfoundation -list_devices true -i "" > "$PROBE_OUT" 2>&1 &
  probe_pid=$!
  i=0
  while kill -0 "$probe_pid" 2>/dev/null; do
    i=$(( i + 1 ))
    if [ "$i" -ge "$DEVLIST_TIMEOUT" ]; then
      kill -9 "$probe_pid" 2>/dev/null
      wait "$probe_pid" 2>/dev/null
      return 124
    fi
    sleep 1
  done
  wait "$probe_pid" 2>/dev/null
  return 0
}

# Video half of the probe output, as "<index>\t<name>". Screen-capture pseudo-devices are
# dropped here and can never be selected, whatever the config says.
parse_video_devices() {
  awk '
    /AVFoundation video devices:/ { v = 1; next }
    /AVFoundation audio devices:/ { v = 0 }
    v && match($0, /\[[0-9]+\]/) {
      idx = substr($0, RSTART + 1, RLENGTH - 2)
      name = substr($0, RSTART + RLENGTH + 1)
      sub(/^[ \t]+/, "", name); sub(/[ \t]+$/, "", name)
      if (name ~ /^Capture screen/) next
      printf "%s\t%s\n", idx, name
    }' "$PROBE_OUT"
}

if ! probe_devices; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') capture-stream.sh: CAMERA ENUMERATION HUNG — avfoundation did not answer -list_devices within ${DEVLIST_TIMEOUT}s. The camera subsystem is wedged, not the software; restarting capture will not clear it. Fix on the machine: 'sudo killall AppleCameraAssistant UVCAssistant' (they respawn on demand), then 'ojogato off && ojogato on'." >> "$LOG"
  rm -f "$PROBE_OUT"
  exec sleep 300
fi

DEVICES=$(parse_video_devices)
rm -f "$PROBE_OUT"
WANT="${OJOGATO_DEVICE_NAME:-}"

if [ -z "$DEVICES" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') capture-stream.sh: NO CAMERA. avfoundation lists no video device (screen-capture entries excluded). Not starting — refusing to fall back to a device index, which would select the screen. On macOS this usually means the CoreMediaIO assistants are wedged: 'sudo killall AppleCameraAssistant UVCAssistant' (they respawn on demand), then 'ojogato off && ojogato on'." >> "$LOG"
  # Sleep rather than exit: launchd KeepAlive would otherwise spin, and no amount of
  # restarting fixes a camera that is not on the bus.
  exec sleep 300
fi

DEV=""
if [ -n "$WANT" ]; then
  DEV=$(printf '%s\n' "$DEVICES" | awk -F'\t' -v w="$WANT" 'index($2, w) == 1 { print $1; exit }')
  if [ -z "$DEV" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') capture-stream.sh: OJOGATO_DEVICE_NAME='$WANT' matches none of the present cameras:" >> "$LOG"
    printf '%s\n' "$DEVICES" >> "$LOG"
    exec sleep 300
  fi
else
  # No name configured: take the first real camera. Deterministic, and still cannot be a screen.
  DEV=$(printf '%s\n' "$DEVICES" | head -1 | cut -f1)
fi
DEV_NAME=$(printf '%s\n' "$DEVICES" | awk -F'\t' -v d="$DEV" '$1 == d { print $2; exit }')
echo "$(date '+%Y-%m-%d %H:%M:%S') capture-stream.sh: capturing from [$DEV] $DEV_NAME" >> "$LOG"

exec "$FFMPEG" -hide_banner -loglevel info \
  -f avfoundation -framerate 30 -video_size "$RES" -i "$DEV" \
  -vf "fps=${FPS},format=yuv420p" \
  -c:v h264_videotoolbox -b:v "$BR" -maxrate "$MAXRATE" -g "$GOP" \
  -an -f rtsp rtsp://127.0.0.1:8554/cam 2>>"$LOG"

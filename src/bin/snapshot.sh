#!/bin/bash
# One live frame from the loopback stream, downscaled, for an agent to look at (the MCP
# server's get_snapshot tool). Never sends anywhere.
# Usage: snapshot.sh [--max-width N]   (default 768; never upscales)
#
# Prints {"path","taken_at","width","height","luma","dark"}. The file lands in frames/
# (the only directory the MCP media endpoint serves) as snap-live-<epoch>.jpg, under the
# snap-* prefix report.sh already tidies.
#
# Stream down — or ojogato paused, which means the camera is meant to be off — exits 2
# with {"error":"stream down"}. Paused is checked first on purpose: a privacy switch that
# an agent could see through would be no switch at all.
#
# OJOGATO_SNAPSHOT_SRC overrides the input (tests point it at a file; default is the
# loopback RTSP). The grab is bounded so a mediamtx that accepts the connection but has no
# publisher can't hang the caller.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
BIN="$OJOGATO_HOME/bin"
. "$BIN/ojogato-json.sh"
[ -f "$OJOGATO_HOME/config.env" ] && source "$OJOGATO_HOME/config.env"

MAXW=768
while [ $# -gt 0 ]; do
  case "$1" in
    --max-width) MAXW="$2"; shift 2 ;;
    --json)      shift ;;   # JSON is the only output mode; accepted for symmetry
    *) json_fail 2 "unknown option $1" ;;
  esac
done
case "$MAXW" in ''|*[!0-9]*) json_fail 2 "--max-width needs a positive integer" ;; esac
[ "$MAXW" -ge 16 ] || json_fail 2 "--max-width needs a positive integer"

[ -f "$OJOGATO_HOME/PAUSED" ] && json_fail 2 "stream down"

FFMPEG="$BIN/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"
[ -n "$FFMPEG" ] || json_fail 1 "ffmpeg not found"

SRC="${OJOGATO_SNAPSHOT_SRC:-rtsp://127.0.0.1:8554/cam}"
mkdir -p "$OJOGATO_HOME/frames"
NOW=$(date +%s)
OUT="$OJOGATO_HOME/frames/snap-live-$NOW.jpg"
rm -f "$OUT"
case "$SRC" in
  rtsp://*) IN_OPTS="-rtsp_transport tcp -timeout 5000000" ;;
  *)        IN_OPTS="" ;;
esac
# shellcheck disable=SC2086
"$FFMPEG" -nostdin -y -loglevel error $IN_OPTS -i "$SRC" -frames:v 1 \
  -vf "scale='min(iw,$MAXW)':-2" -q:v 4 -update 1 "$OUT" </dev/null >/dev/null 2>&1 &
PID=$!
i=0
while kill -0 "$PID" 2>/dev/null; do
  [ "$i" -ge 150 ] && { kill "$PID" 2>/dev/null; break; }   # 15s hard bound
  sleep 0.1; i=$(( i + 1 ))
done
wait "$PID" 2>/dev/null
[ -s "$OUT" ] || { rm -f "$OUT"; json_fail 2 "stream down"; }

PROBE=$("$FFMPEG" -hide_banner -i "$OUT" 2>&1)
DIM=$(printf '%s\n' "$PROBE" | grep 'Video:' | grep -oE '[0-9]{2,5}x[0-9]{2,5}' | head -1)
W=${DIM%x*}; H=${DIM#*x}
[ -n "$DIM" ] || json_fail 1 "could not read snapshot dimensions"
LUMA=$(yavg_of "$FFMPEG" "$OUT")

# Old live snapshots go once any signed media URL for them has long expired.
TTL_MIN=$(( ${OJOGATO_MCP_MEDIA_TTL:-3600} / 60 + 60 ))
find "$OJOGATO_HOME/frames" -name 'snap-live-*.jpg' -mmin +"$TTL_MIN" -delete 2>/dev/null

printf '{"path":%s,"taken_at":%d,"width":%d,"height":%d,"luma":%s,"dark":%s}\n' \
  "$(json_str "$OUT")" "$NOW" "$W" "$H" "$(json_num_or_null "${LUMA:-0}")" "$(dark_json "${LUMA:-0}")"

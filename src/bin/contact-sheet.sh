#!/bin/bash
# Contact sheet: N frames sampled evenly from a video, tiled left-to-right into one JPEG,
# so an agent that can look at images but not watch video can see what a clip shows.
# Usage: contact-sheet.sh <video> [--frames 3] [--width 768]
#
#   --width is the width of the WHOLE sheet (each tile is width/frames), which keeps the
#   image an agent receives bounded no matter how many frames it asks for.
#
# Prints {"path","frames"}; frames is how many tiles actually made it in. The sheet lands
# in frames/ (the only directory the MCP media endpoint serves) as contact-<video>.jpg.
# Samples sit at the middle of N equal slices — (i + 0.5) / N — never at 0 or the very
# end, where a cut clip is most likely to hold a half-decoded or black frame.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
BIN="$OJOGATO_HOME/bin"
. "$BIN/ojogato-json.sh"
[ -f "$OJOGATO_HOME/config.env" ] && source "$OJOGATO_HOME/config.env"

VIDEO=""; N=3; WIDTH=768
while [ $# -gt 0 ]; do
  case "$1" in
    --frames) N="$2"; shift 2 ;;
    --width)  WIDTH="$2"; shift 2 ;;
    --json)   shift ;;   # JSON is the only output mode; accepted for symmetry
    -*) json_fail 2 "unknown option $1" ;;
    *)  VIDEO="$1"; shift ;;
  esac
done
[ -n "$VIDEO" ] || json_fail 2 "usage: contact-sheet.sh <video> [--frames 3] [--width 768]"
case "$N" in ''|*[!0-9]*) json_fail 2 "--frames needs an integer 1-12" ;; esac
case "$WIDTH" in ''|*[!0-9]*) json_fail 2 "--width needs a positive integer" ;; esac
[ "$N" -ge 1 ] && [ "$N" -le 12 ] || json_fail 2 "--frames needs an integer 1-12"
[ "$WIDTH" -ge "$(( N * 16 ))" ] || json_fail 2 "--width too small for $N frames"
[ -s "$VIDEO" ] || json_fail 1 "no such video: $VIDEO"
case "$VIDEO" in /*) ;; *) VIDEO="$(cd "$(dirname "$VIDEO")" && pwd)/$(basename "$VIDEO")" ;; esac

FFMPEG="$BIN/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"
[ -n "$FFMPEG" ] || json_fail 1 "ffmpeg not found"

# Duration from ffmpeg's own header line ("Duration: 00:00:14.03"), no ffprobe needed.
# Fragmented mp4 (what record.sh writes) has no header duration — "Duration: N/A" — so
# fall back to a stream-copy pass and read the final time= it reports.
hms() { awk -F: '{print $1 * 3600 + $2 * 60 + $3}'; }
DUR=$("$FFMPEG" -hide_banner -i "$VIDEO" 2>&1 | grep -oE 'Duration: [0-9]+:[0-9]{2}:[0-9.]+' | head -1 \
  | sed 's/Duration: //' | hms)
if [ -z "$DUR" ]; then
  DUR=$("$FFMPEG" -nostdin -hide_banner -i "$VIDEO" -map 0:v:0 -c copy -f null - 2>&1 | tr '\r' '\n' \
    | grep -oE 'time=[0-9]+:[0-9]{2}:[0-9.]+' | tail -1 | sed 's/time=//' | hms)
fi
if [ -z "$DUR" ] || ! awk "BEGIN{exit !($DUR > 0)}"; then json_fail 1 "could not read the video's duration"; fi

mkdir -p "$OJOGATO_HOME/frames"
TMP=$(mktemp -d "$OJOGATO_HOME/frames/.contact.XXXXXX") || json_fail 1 "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
TILE_W=$(( WIDTH / N ))
K=0; i=0
while [ "$i" -lt "$N" ]; do
  T=$(awk "BEGIN{printf \"%.3f\", $DUR * ($i + 0.5) / $N}")
  "$FFMPEG" -nostdin -y -loglevel error -ss "$T" -i "$VIDEO" -frames:v 1 \
    -vf "scale=$TILE_W:-2" -q:v 4 "$TMP/raw.jpg" 2>/dev/null
  if [ -s "$TMP/raw.jpg" ]; then
    K=$(( K + 1 )); mv "$TMP/raw.jpg" "$TMP/t$(printf '%02d' "$K").jpg"
  fi
  i=$(( i + 1 ))
done
[ "$K" -gt 0 ] || json_fail 1 "could not decode any frame from the video"

OUT="$OJOGATO_HOME/frames/contact-$(basename "$VIDEO" | sed 's/\.[^.]*$//').jpg"
rm -f "$OUT"
"$FFMPEG" -nostdin -y -loglevel error -framerate 1 -i "$TMP/t%02d.jpg" \
  -vf "tile=${K}x1" -frames:v 1 -q:v 4 "$OUT" 2>/dev/null
[ -s "$OUT" ] || json_fail 1 "tiling the contact sheet failed"

TTL_MIN=$(( ${OJOGATO_MCP_MEDIA_TTL:-3600} / 60 + 60 ))
find "$OJOGATO_HOME/frames" -maxdepth 1 -name 'contact-*.jpg' -mmin +"$TTL_MIN" -delete 2>/dev/null

printf '{"path":%s,"frames":%d}\n' "$(json_str "$OUT")" "$K"

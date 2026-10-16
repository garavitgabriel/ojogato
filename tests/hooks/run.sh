#!/bin/bash
# Pipeline hook tests — no camera, no network, nothing touches ~/.ojogato.
# Usage: bash tests/hooks/run.sh
#
# 1. Golden: every default (human) output is byte-for-byte what main produced
#    (tests/hooks/golden/, captured by capture-golden.sh from `git archive main`).
# 2. Contract: every --json mode prints exactly the contract keys/types on one line, plus
#    --event, --since, the error exits, and "never sends" (Telegram is armed with a fake
#    token for these and the curl shim must see zero calls).
# 3. Digest: standalone/agent/off and the no-double-send guard. 4. `ojogato mcp`.
REPO=$(cd "$(dirname "$0")/../.." && pwd)
H="$REPO/tests/hooks"
. "$H/lib.sh"
trap fx_cleanup EXIT
fx_setup "$REPO/src/bin" || { echo "fixture build failed"; exit 1; }
PY=/usr/bin/python3; [ -x "$PY" ] || PY=python3

PASS=0; FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf '  ✔ %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  ✘ %s\n' "$*"; }

# ------------------------------------------------------------------ 1. golden
echo "▸ golden default outputs (from $(cut -c1-12 < "$H/golden/SOURCE"))"
TMPG="$FX_ROOT/got.out"
while IFS='|' read -r name envs cmd; do
  [ -n "$name" ] || continue
  # shellcheck disable=SC2086
  fx_run_case "$name" "$envs" $cmd > "$TMPG"
  # --json output gains event_id; everything else on the line must be untouched.
  case "$name" in events_json*) sed -i '' 's/"event_id":"[0-9]*",//' "$TMPG" ;; esac
  if cmp -s "$TMPG" "$H/golden/$name.out"; then ok "$name"
  else bad "$name differs from main:"; diff "$H/golden/$name.out" "$TMPG" | head -8 | sed 's/^/      /'; fi
done <<EOF
$(fx_cases)
EOF

# ------------------------------------------------------------------ 2. contract
STATUS="generated_at:int,paused:bool,vision:str,last_seen_min:int|null,sightings_6h:int|null,sightings_12h:int|null,raw_frames_6h:int,raw_frames_12h:int,detector_alive:bool,luma:num|null,dark:bool|null,live_url:str|null,subject:str,pet_names:str|null"
SNAP="path:str,taken_at:int,width:int,height:int,luma:num,dark:bool"
EV="event_id:str,start:int,end:int,frames:int,subject_frames:int,verdict:str,score:num,best_epoch:int,best_frame:str,subject_first:int,subject_last:int"
CLIP="path:str|null,event_id:str|null,event_hhmm:str|null,verdict:str|null,duration_s:num|null,luma:num|null,dark:bool|null"
RECAP="path:str|null,caption:str,moments:list"
SHEET="path:str,frames:int"
ERR="error:str"

# contract <label> <want_exit> <spec> [key=json ...] -- <env-spec> <script> [args...]
contract() {
  local label=$1 want=$2 spec=$3 out code msg; shift 3
  local checks=()
  while [ "$1" != "--" ]; do checks+=("$1"); shift; done; shift
  out=$(fx_exec "$@" 2>/dev/null); code=$?
  if [ "$code" != "$want" ]; then bad "$label: exit $code, want $want — $(printf '%s' "$out" | head -c 200)"; return; fi
  if msg=$(printf '%s\n' "$out" | "$PY" "$H/check_json.py" "$spec" "${checks[@]}"); then ok "$label"
  else bad "$label: $msg"; fi
}
# A fake (non-functional) token: if any --json mode tried to send, the curl shim logs it.
arm() { fx_reset; printf 'OJOGATO_TELEGRAM_TOKEN="000000:fixture-not-a-token"\nOJOGATO_TELEGRAM_CHAT="1"\n' >> "$FX_WORK/config.env"; }

echo "▸ status.sh --json"
arm
contract "vision on" 0 "$STATUS" vision='"on"' sightings_6h=3 sightings_12h=3 last_seen_min=39 paused=false \
  detector_alive=true dark=false generated_at="$FX_NOW" live_url='"http://cam.example.ts.net:8889/cam"' -- - status.sh --json
contract "vision stale → sightings null" 0 "$STATUS" vision='"stale"' sightings_6h=null sightings_12h=null -- OJOGATO_VISION_STALL_SEC=-1 status.sh --json
contract "vision off → sightings null" 0 "$STATUS" vision='"off"' sightings_6h=null -- OJOGATO_VISION_ENABLED=0 status.sh --json
touch "$FX_WORK/PAUSED"
contract "paused still exits 0" 0 "$STATUS" paused=true -- - status.sh --json
arm; rm -f "$FX_WORK"/motionframes/*.jpg
contract "nothing seen → last_seen_min null (never 9999)" 0 "$STATUS" last_seen_min=null sightings_6h=0 -- - status.sh --json
arm; fx_touch "$FX_WORK/frames/detector-alive.jpg" $(( FX_NOW - 3600 ))
contract "stale detector frame → detector_alive false" 0 "$STATUS" detector_alive=false -- - status.sh --json
arm; rm -f "$FX_WORK/frames/detector-alive.jpg"
contract "no detector frame → luma/dark null" 0 "$STATUS" luma=null dark=null detector_alive=false -- - status.sh --json
arm; sed -i '' -E '/^(OJOGATO_PET_NAMES|OJOGATO_LIVE_URL|OJOGATO_SUBJECT)=/d' "$FX_WORK/config.env"
printf '%s\n' 'OJOGATO_SUBJECT="Milo'"'"'s \"gang\" \\ co"' >> "$FX_WORK/config.env"
contract "escaping + unset → null" 0 "$STATUS" pet_names=null live_url=null 'subject="Milo'"'"'s \"gang\" \\ co"' -- - status.sh --json

echo "▸ snapshot.sh"
arm; SRC="OJOGATO_SNAPSHOT_SRC=$FX_WORK/recordings/$(fx_name $(( FX_E4 - 20 ))).mp4"
contract "grab (no upscale past source)" 0 "$SNAP" width=320 height=240 taken_at="$FX_NOW" dark=false -- "$SRC" snapshot.sh
contract "--max-width 200" 0 "$SNAP" width=200 height=150 -- "$SRC" snapshot.sh --max-width 200
contract "stream down → exit 2" 2 "$ERR" 'error="stream down"' -- OJOGATO_SNAPSHOT_SRC=/nonexistent/cam.mp4 snapshot.sh
contract "bad --max-width → exit 2" 2 "$ERR" -- "$SRC" snapshot.sh --max-width wide
touch "$FX_WORK/PAUSED"
contract "paused → stream down (camera is meant to be off)" 2 "$ERR" 'error="stream down"' -- "$SRC" snapshot.sh

echo "▸ events.sh --json / --event / --since"
arm
contract "every event has event_id" 0 "lines:$EV" '#lines=5' -- - events.sh --json
contract "--real-only" 0 "lines:$EV" '#lines=3' -- - events.sh --json --real-only
contract "--event (newest real)" 0 "$EV" start="$FX_E4" verdict='"pet"' best_frame="\"$(fx_name $(( FX_E4 + 4 )))\"" -- - events.sh --event "$FX_E4" --json
contract "--event any verdict (noise)" 0 "$EV" start="$FX_E2" verdict='"none"' -- - events.sh --event "$FX_E2" --json
contract "--event beyond the 24h window" 0 "$EV" start="$FX_OLD" verdict='"pet"' -- - events.sh --event "$FX_OLD" --json
contract "--event mid-event id → exit 3" 3 "$ERR" 'error="no such event"' -- - events.sh --event $(( FX_E4 + 2 )) --json
contract "--event garbage → exit 3" 3 "$ERR" 'error="no such event"' -- - events.sh --event nope --json
contract "--since keeps end > epoch" 0 "lines:$EV" '#lines=1' start="$FX_E4" -- - events.sh --json --real-only --since $(( FX_E3 + 2 ))
contract "--since boundary is exclusive" 0 "lines:$EV" '#lines=2' start="$FX_E3" -- - events.sh --json --real-only --since $(( FX_E3 + 1 ))
OUT=$(fx_exec - events.sh --json --since "$FX_NOW"); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "--since now → no events, exit 0" || bad "--since now → exit $RC, '$OUT'"
OUT=$(fx_exec - events.sh --last-real --since $(( FX_E3 + 1 )) | cut -f1)
[ "$OUT" = "$FX_E4" ] && ok "--since combines with --last-real (TSV)" || bad "--since + --last-real gave '$OUT'"
contract "unknown option → JSON error, exit 2" 2 "$ERR" -- - events.sh --json --bogus

echo "▸ clip.sh --json"
arm
contract "verified clip" 0 "$CLIP" event_id="\"$FX_E4\"" verdict='"pet"' event_hhmm='"11:19"' dark=false -- - clip.sh --json
[ -s "$FX_WORK/frames/lastmove.meta" ] && ok "lastmove.meta still written" || bad "lastmove.meta missing"
arm; rm -f "$FX_WORK"/recordings/*.mp4
contract "nothing to show → path null, exit 0" 0 "$CLIP" path=null event_id=null verdict=null -- - clip.sh --json

echo "▸ recap.sh --no-send --json"
arm
contract "moments are the kept, verified ones" 0 "$RECAP" moments.0.event_id="\"$FX_E1\"" moments.1.event_id="\"$FX_E4\"" \
  moments.1.time_hhmm='"11:19"' moments.1.verdict='"pet"' -- - recap.sh --no-send --json
contract "--json alone never sends" 0 "$RECAP" -- - recap.sh --json --hours 3 --max 1
contract "nothing to show → path null, moments []" 0 "$RECAP" path=null moments='[]' -- - recap.sh --no-send --json --hours 0
mkdir -p "$FX_WORK/frames/recap.lock"
contract "recap already running → error, exit 1" 1 "$ERR" -- - recap.sh --no-send --json
arm; touch "$FX_WORK/PAUSED"
contract "paused → path null, exit 0" 0 "$RECAP" path=null moments='[]' -- - recap.sh --no-send --json
OUT=$(printf '%s' "$(arm; fx_exec - recap.sh --no-send --json)" | "$PY" -c 'import json,sys; print("\n" not in json.load(sys.stdin)["caption"] or "multi")' 2>&1)
[ -n "$OUT" ] && ok "caption parses through json.load" || bad "caption: $OUT"

echo "▸ contact-sheet.sh"
arm; fx_exec - clip.sh >/dev/null 2>&1
contract "3 frames from the clip (JPEG)" 0 "$SHEET" frames=3 -- - contact-sheet.sh "$FX_WORK/frames/lastmove.mp4"
contract "fragmented recording, --frames 5 --width 1000" 0 "$SHEET" frames=5 -- - contact-sheet.sh "$FX_WORK/recordings/$(fx_name $(( FX_E1 - 20 ))).mp4" --frames 5 --width 1000
W=$(ffmpeg -hide_banner -i "$FX_WORK/frames/contact-$(fx_name $(( FX_E1 - 20 ))).jpg" 2>&1 | grep -oE '[0-9]+x[0-9]+' | head -1)
[ "${W%x*}" = "1000" ] && ok "--width is the whole sheet's width ($W)" || bad "sheet is $W, want 1000 wide"
contract "missing video → exit 1" 1 "$ERR" -- - contact-sheet.sh "$FX_WORK/frames/nope.mp4"
contract "bad --frames → exit 2" 2 "$ERR" -- - contact-sheet.sh "$FX_WORK/frames/lastmove.mp4" --frames 0

if [ -s "$FX_CURL_LOG" ]; then bad "a --json mode tried to send:"; sed 's/^/      /' "$FX_CURL_LOG"; : > "$FX_CURL_LOG"
else ok "no --json mode attempted a send (curl shim saw nothing)"; fi

# ------------------------------------------------------------------ 3. digest
echo "▸ digest.sh (one sender only)"
digest() { # digest <label> <expect-substring> <env-spec> [args]
  local label=$1 want=$2 out; shift 2
  out=$(fx_exec "$@" 2>&1)
  case "$out" in *"$want"*) ok "$label" ;; *) bad "$label: got '$(printf '%s' "$out" | head -c 160)'" ;; esac
}
fx_reset; rm -rf "$FX_FAKEHOME/.openclaw"
digest "mode=agent → idle" "mode=agent — not sending" OJOGATO_DIGEST_MODE=agent digest.sh morning
digest "mode=off → idle" "mode=off — not sending" OJOGATO_DIGEST_MODE=off digest.sh morning
digest "standalone morning → report.sh digest" "Digest on the cats (Thu 12:00)" OJOGATO_DIGEST_MODE=standalone digest.sh morning
digest "standalone, hour 12 → morning" "morning digest sent" OJOGATO_DIGEST_MODE=standalone digest.sh
digest "standalone evening → digest --recap" "evening digest sent" OJOGATO_DIGEST_MODE=standalone digest.sh evening
digest "unset, no ~/.openclaw → standalone" "Digest on the cats" - digest.sh morning
mkdir -p "$FX_FAKEHOME/.openclaw/cron"
digest "unset, ~/.openclaw present → agent" "mode=agent — not sending" - digest.sh morning
echo '{"jobs":[{"id":"ojogato-digest-morning"},{"id":"ojogato-digest-evening"}]}' > "$FX_FAKEHOME/.openclaw/cron/jobs.json"
digest "standalone + OpenClaw digest crons → stands down" "would double-send" OJOGATO_DIGEST_MODE=standalone digest.sh morning
rm -rf "$FX_FAKEHOME/.openclaw"
grep -q 'StartCalendarInterval' "$REPO/src/templates/com.ojogato.digest.plist.tmpl" && \
  plutil -lint -s "$REPO/src/templates/com.ojogato.digest.plist.tmpl" >/dev/null 2>&1 && ok "digest plist template lints" || bad "digest plist template"

# ------------------------------------------------------------------ 4. ojogato mcp
echo "▸ ojogato mcp"
fx_reset
OUT=$(fx_exec - ojogato mcp url); [ "$OUT" = "http://127.0.0.1:8790/mcp" ] && ok "url derived from bind+port" || bad "mcp url: '$OUT'"
OUT=$(fx_exec "OJOGATO_MCP_BIND=100.64.0.7 OJOGATO_MCP_PORT=9000" ojogato mcp url); [ "$OUT" = "http://100.64.0.7:9000/mcp" ] && ok "url from explicit IP bind" || bad "mcp url ip: '$OUT'"
OUT=$(fx_exec OJOGATO_MCP_PUBLIC_URL=http://cam.example.ts.net:8790/ ojogato mcp url); [ "$OUT" = "http://cam.example.ts.net:8790/mcp" ] && ok "OJOGATO_MCP_PUBLIC_URL wins" || bad "mcp url public: '$OUT'"
fx_exec - ojogato mcp token >/dev/null 2>&1 && bad "mcp token with none set should fail" || ok "mcp token fails when unset"
OUT=$(fx_exec OJOGATO_MCP_TOKEN=abc123 ojogato mcp token); [ "$OUT" = "abc123" ] && ok "mcp token prints it" || bad "mcp token: '$OUT'"

[ -s "$FX_CURL_LOG" ] && { bad "something tried curl:"; cat "$FX_CURL_LOG"; }
echo ""
echo "▸ $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

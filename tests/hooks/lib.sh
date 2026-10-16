#!/bin/bash
# Shared fixture + golden case list for tests/hooks/run.sh and capture-golden.sh.
#
# The fixture is a fake OJOGATO_HOME with synthetic motion frames, a verdict cache, two
# short ffmpeg-generated fragmented-mp4 recordings and a detector-alive frame. Time is
# FROZEN: a `date` shim on PATH answers every "now" question with FX_NOW, and every file's
# mtime is set to the epoch in its name, so the default (human) outputs are byte-stable
# and can be compared against goldens captured from `main`. TZ is pinned to UTC because
# `date -j -f` and `date -r … +%H:%M` are timezone-dependent.
#
# Consequence of frozen time: `find -mmin` still reads the real clock, so the raw
# frame counts (MOTION_FRAMES_LAST_*H / raw_frames_*) read 0 here. That is deterministic,
# which is what a golden needs; the JSON key/type checks don't depend on the value.
#
# Nothing here can reach the network: the fixture config sets the Telegram token/chat to
# "" explicitly, and a `curl` shim on PATH refuses and logs every call.

export TZ=UTC
FX_NOW=$(/bin/date -j -u -f "%Y%m%d-%H%M%S" "20260115-120000" +%s)

fx_name()  { /bin/date -u -r "$1" +%Y%m%d-%H%M%S; }
fx_touch() { touch -t "$(/bin/date -u -r "$2" +%Y%m%d%H%M.%S)" "$1"; }

# fx_frame <home> <epoch> [verdict score]  — no verdict = still pending in vision
fx_frame() {
  local b; b=$(fx_name "$2")
  cp "$FX_ROOT/tpl.jpg" "$1/motionframes/$b.jpg"
  fx_touch "$1/motionframes/$b.jpg" "$2"
  if [ -n "$3" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$b" "$3" "$4" "fixture" >> "$1/vision/verdicts.tsv"
  fi
}

# fx_recording <home> <start_epoch> — 40s fragmented mp4, named like record.sh names them
fx_recording() {
  local f; f="$1/recordings/$(fx_name "$2").mp4"
  ffmpeg -nostdin -y -loglevel error -f lavfi -i "testsrc2=s=320x240:r=12" -t 40 \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -movflags +frag_keyframe+empty_moov+default_base_moof "$f" || return 1
  fx_touch "$f" "$(( $2 + 40 ))"
}

# Event layout (relative to FX_NOW = 2026-01-15 12:00:00 UTC):
#   OLD  -30h     pet (outside the 24h default window; reachable via --event / --hours 48)
#   E1   -5h      pet, 3 frames, recording present
#   E2   -3h      noise: 4 frames all "none"
#   E3   -2h      person, no recording (recap must skip it, not fake it)
#   E4   -40min   pet (cat/dog collapse), 5 frames, recording present — the last real event
#   E5   -10min   pending: frames not classified yet
fx_events() {
  local h=$1 N=$FX_NOW
  FX_OLD=$(( N - 30 * 3600 )); FX_E1=$(( N - 5 * 3600 )); FX_E2=$(( N - 3 * 3600 ))
  FX_E3=$(( N - 2 * 3600 ));   FX_E4=$(( N - 40 * 60 ));  FX_E5=$(( N - 10 * 60 ))
  fx_frame "$h" "$FX_OLD" cat 0.700; fx_frame "$h" $(( FX_OLD + 2 )) none 0
  fx_frame "$h" "$FX_E1" none 0; fx_frame "$h" $(( FX_E1 + 2 )) cat 0.820; fx_frame "$h" $(( FX_E1 + 4 )) none 0
  fx_frame "$h" "$FX_E2" none 0; fx_frame "$h" $(( FX_E2 + 3 )) none 0
  fx_frame "$h" $(( FX_E2 + 6 )) none 0; fx_frame "$h" $(( FX_E2 + 9 )) none 0
  fx_frame "$h" "$FX_E3" person 0.600; fx_frame "$h" $(( FX_E3 + 2 )) person 0.550
  fx_frame "$h" "$FX_E4" none 0; fx_frame "$h" $(( FX_E4 + 2 )) dog 0.700
  fx_frame "$h" $(( FX_E4 + 4 )) cat 0.910; fx_frame "$h" $(( FX_E4 + 6 )) cat 0.500
  fx_frame "$h" $(( FX_E4 + 8 )) none 0
  fx_frame "$h" "$FX_E5"; fx_frame "$h" $(( FX_E5 + 2 ))
}

# fx_setup <bin_source_dir> — builds the template home once under FX_ROOT
fx_setup() {
  FX_BINSRC=$1
  FX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ojogato-hooks.XXXXXX") || return 1
  FX_ROOT=$(cd "$FX_ROOT" && pwd -P)
  FX_TPL="$FX_ROOT/tpl-home"; FX_WORK="$FX_ROOT/home"; FX_SHIMS="$FX_ROOT/shims"
  FX_CURL_LOG="$FX_ROOT/curl.log"; FX_FAKEHOME="$FX_ROOT/user"
  FX_FFDIR=$(dirname "$(command -v ffmpeg)")
  mkdir -p "$FX_SHIMS" "$FX_FAKEHOME"

  cat > "$FX_SHIMS/date" <<'EOF'
#!/bin/bash
# Frozen clock: any invocation that asks about "now" gets OJOGATO_TEST_NOW.
for a in "$@"; do case "$a" in -r|-j|-u*) exec /bin/date "$@" ;; esac; done
exec /bin/date -r "$OJOGATO_TEST_NOW" "$@"
EOF
  cat > "$FX_SHIMS/curl" <<'EOF'
#!/bin/bash
echo "curl blocked: $*" >> "$OJOGATO_TEST_CURL_LOG"
exit 7
EOF
  # recap.sh labels moments with drawtext; Homebrew's ffmpeg is built without freetype, and
  # without this shim every moment cut fails and the recap success path is never exercised.
  # The shim only drops the label when the real ffmpeg lacks the filter.
  STRIP=0
  ffmpeg -hide_banner -filters 2>/dev/null | grep -q ' drawtext ' || STRIP=1
  cat > "$FX_SHIMS/ffmpeg" <<EOF
#!/bin/bash
REAL="$(command -v ffmpeg)"
[ "$STRIP" = "1" ] || exec "\$REAL" "\$@"
args=(); prev=""
for a in "\$@"; do
  o=\$a
  [ "\$prev" = "-vf" ] && a="\${a%%,drawtext=*}"
  args+=("\$a"); prev=\$o
done
exec "\$REAL" "\${args[@]}"
EOF
  chmod +x "$FX_SHIMS/date" "$FX_SHIMS/curl" "$FX_SHIMS/ffmpeg"

  ffmpeg -nostdin -y -loglevel error -f lavfi -i "color=c=0x606060:s=320x240" -frames:v 1 "$FX_ROOT/tpl.jpg" || return 1

  local h=$FX_TPL f
  mkdir -p "$h/bin" "$h/recordings" "$h/motionframes" "$h/frames" "$h/logs" "$h/vision"
  for f in "$FX_BINSRC"/*; do ln -s "$f" "$h/bin/$(basename "$f")"; done
  cat > "$h/config.env" <<'EOF'
OJOGATO_TELEGRAM_TOKEN=""
OJOGATO_TELEGRAM_CHAT=""
OJOGATO_LIVE_URL="http://cam.example.ts.net:8889/cam"
OJOGATO_SUBJECT="the cats"
OJOGATO_PET_NAMES="Milo, Lila"
OJOGATO_DARK_YAVG="16"
EOF
  : > "$h/vision/verdicts.tsv"
  fx_events "$h"
  fx_recording "$h" $(( FX_E1 - 20 )) || return 1
  fx_recording "$h" $(( FX_E4 - 20 )) || return 1
  cp "$FX_ROOT/tpl.jpg" "$h/frames/detector-alive.jpg"
  fx_touch "$h/frames/detector-alive.jpg" $(( FX_NOW - 10 ))
  echo "$FX_NOW" > "$h/vision/verifier-alive"
}

fx_reset() { rm -rf "$FX_WORK"; cp -Rp "$FX_TPL" "$FX_WORK"; }

# fx_exec <env-spec|-> <script> [args...] — run one script inside the fixture, isolated env.
fx_exec() {
  local envs=$1 s=$2; shift 2
  [ "$envs" = "-" ] && envs=""
  # shellcheck disable=SC2086
  env -i HOME="$FX_FAKEHOME" PATH="$FX_SHIMS:/usr/bin:/bin:/usr/sbin:/sbin:$FX_FFDIR" TZ=UTC \
    OJOGATO_HOME="$FX_WORK" OJOGATO_TEST_NOW="$FX_NOW" OJOGATO_TEST_CURL_LOG="$FX_CURL_LOG" \
    $envs "$FX_WORK/bin/$s" "$@"
}

# Golden cases: name|env-spec|script args. Default (human) outputs only — these must stay
# byte-for-byte identical to main. `*_paused` cases run with the PAUSED flag set.
fx_cases() {
  cat <<'EOF'
events_default|-|events.sh
events_real|-|events.sh --real-only
events_last|-|events.sh --last-real
events_h6|-|events.sh --hours 6
events_h48|-|events.sh --hours 48
events_h0|-|events.sh --hours 0
events_json|-|events.sh --json
events_json_real|-|events.sh --json --real-only
mstats6|-|motion-stats.sh 6
mstats12|-|motion-stats.sh 12
mstats6_novision|OJOGATO_VISION_ENABLED=0|motion-stats.sh 6
mstats6_stale|OJOGATO_VISION_STALL_SEC=-1|motion-stats.sh 6
clip|-|clip.sh
clip_novision|OJOGATO_VISION_ENABLED=0|clip.sh
recap_nosend|-|recap.sh --no-send
recap_h3|-|recap.sh --no-send --hours 3
recap_h0|-|recap.sh --no-send --hours 0
recap_default|-|recap.sh
recap_paused|-|recap.sh --no-send
report_now|-|report.sh now
report_digest|-|report.sh digest
report_digest_recap|-|report.sh digest --recap
report_stale|OJOGATO_VISION_STALL_SEC=-1|report.sh now
report_paused|-|report.sh now
EOF
}

# fx_run_case <name> <env-spec> <cmd...> — prints the normalised transcript of one case
fx_run_case() {
  local name=$1 envs=$2 out code; shift 2
  fx_reset
  case "$name" in *_paused) touch "$FX_WORK/PAUSED" ;; esac
  # shellcheck disable=SC2086
  out=$(fx_exec "$envs" $* 2>/dev/null); code=$?
  {
    printf '%s\n--- exit: %s\n' "$out" "$code"
    if [ -f "$FX_WORK/frames/lastmove.meta" ]; then
      echo "--- lastmove.meta:"; cat "$FX_WORK/frames/lastmove.meta"
    fi
  } | sed "s|$FX_WORK|@HOME@|g"
}

fx_cleanup() { [ -n "$FX_ROOT" ] && rm -rf "$FX_ROOT"; }

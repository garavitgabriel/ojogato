#!/bin/bash
# Events: the single definition of "motion" in Ojo de Gato. Everything that reports
# activity — motion-stats.sh, clip.sh, report.sh, heartbeat.sh, `ojogato status` — reads
# this and nothing else, so the count, the "last movement" time and the clip can never
# again disagree about what happened.
#
# WHY THIS EXISTS. The detector's job is to notice that pixels changed; that is all
# mpdecimate can measure. On this camera an empty room changes pixels constantly: the
# webcam's auto-exposure hunts against the blown-out doorway, and a single 8x8 block
# crossing the `hi` threshold is enough to keep a frame. Measured 2026-08-15: 36
# consecutive "motion" frames between 13:37 and 14:03 with nobody in the room, and the
# "last movement" clip sent to the phone was anchored on one such burst at 13:34 — an
# empty room presented as the day's activity. Frame counts were reporting weather on the
# sensor, not cats.
#
# So a frame is a CANDIDATE, not an event. An EVENT is a run of candidate frames no more
# than OJOGATO_EVENT_GAP seconds apart, and it is REAL only if ojogato-vision recognised a
# subject (pet or person) in at least one of its frames.
#
# Event-level, not frame-level, and that distinction is the whole design. Vision misses
# individual frames all the time — a ragdoll with its back turned, low-contrast pale fur
# against pale tile, a person cropped to a forearm at the top of the frame. But a subject
# that is really in the room stays there for seconds and produces a run of frames, and the
# recogniser only has to succeed on ONE of them. Exposure flicker produces runs in which it
# succeeds on none. Validated over a full day: 24 real events, every one with a plausible
# duration and a confident best frame, and zero false positives in a window hand-checked
# as empty.
#
# Usage:
#   events.sh [--hours N] [--real-only] [--last-real] [--json]
#
# Default output is TSV, oldest first, one row per event:
#   start_epoch  end_epoch  n_frames  n_subject  verdict  score  best_epoch  best_frame
# verdict is pet|person|none. "none" means every frame in the event was checked and no
# subject was found — the event is noise. Rows whose frames are not all classified yet are
# reported with verdict "pending"; a caller must not present pending as either activity or
# quiet (see report.sh, which says "verifying" instead of guessing).
#
#   --real-only  emit only pet/person events
#   --last-real  emit only the newest real event (nothing if there is none)
#   --hours N    only consider frames from the last N hours (default 24)
#   --json       emit JSON objects instead of TSV; each carries "event_id" (its start
#                epoch, as a string), the stable handle agents pass back
#   --since E    keep only events that ended after unix epoch E (filters; does not widen
#                --hours). Combines with --real-only / --last-real.
#   --event ID   just that one event, whatever its verdict; ignores --hours, so an id from
#                an earlier listing still resolves while its frames exist. Not found:
#                exit 3 (with --json: {"error":"no such event"} on stdout).
#
# With --json, a bad option is reported as {"error":"…"} on stdout (exit 2).
#
# Species: cat and dog collapse to "pet" here on purpose. Vision's cat/dog split is not
# reliable at this resolution and pale animals read as "dog" in a minority of frames;
# reporting a confident wrong species to someone watching their own cats is worse than
# reporting "pet" and letting OJOGATO_SUBJECT / OJOGATO_PET_NAMES do the naming.
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"

VERDICTS="$OJOGATO_HOME/vision/verdicts.tsv"
FRAMES="$OJOGATO_HOME/motionframes"
GAP="${OJOGATO_EVENT_GAP:-30}"

HOURS=24
REAL_ONLY=0
LAST_REAL=0
JSON=0
EVENT=""
AFTER=""
# Errors go to stdout as {"error":…} when the caller asked for JSON (the agent contract),
# and to stderr as before otherwise.
WANT_JSON=0
for a in "$@"; do [ "$a" = "--json" ] && WANT_JSON=1; done
fail() { # fail <exit> <message>
  if [ "$WANT_JSON" = "1" ]; then
    m=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g'); printf '{"error":"%s"}\n' "$m"
  else
    echo "events.sh: $2" >&2
  fi
  exit "$1"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --hours)     HOURS="$2"; shift 2 ;;
    --real-only) REAL_ONLY=1; shift ;;
    --last-real) LAST_REAL=1; REAL_ONLY=1; shift ;;
    --json)      JSON=1; shift ;;
    --event)     EVENT="$2"; shift 2 ;;
    --since)     AFTER="$2"; shift 2 ;;
    *) fail 2 "unknown option $1" ;;
  esac
done
case "$AFTER" in *[!0-9]*) fail 2 "--since needs a unix epoch" ;; esac
if [ -n "$EVENT" ]; then
  # An event_id is its start epoch. Anything else cannot name an event.
  case "$EVENT" in *[!0-9]*) fail 3 "no such event" ;; esac
  REAL_ONLY=0; LAST_REAL=0; AFTER=""
fi

NOW=$(date +%s)
SINCE=$(( NOW - HOURS * 3600 ))
# Looking one event up ignores --hours: the window starts just before the event, GAP+1
# seconds back, so a frame that would have chained into it (making the real start earlier)
# is still seen — and then the id correctly fails to match.
[ -n "$EVENT" ] && SINCE=$(( EVENT - GAP - 1 ))

# Candidate frames in the window, as "<epoch> <basename>". The epoch comes from the
# FILENAME (the detector writes %Y%m%d-%H%M%S), not from mtime: mtime is rewritten by any
# copy or restore of the frame directory, and an event list that shifts when someone
# rsyncs a backup is not evidence of anything.
#
# Converted a day at a time, not a frame at a time. The obvious loop calls `date -j -f`
# per file, which is one fork per frame — 7,000 forks and ~50 seconds per call on the
# reference install, and report.sh runs this three times. Instead we resolve local
# midnight once per calendar day (two or three forks total) and add the seconds-of-day
# in awk. Exact except across a DST boundary, where frames after the shift are off by
# the shift for the rest of that day; the reference install's timezone has no DST, and
# an hour of skew in an event list is a cosmetic error, not a wrong verdict.
list_frames() {
  DAYS=$(ls "$FRAMES" 2>/dev/null | sed -n 's/^\([0-9]\{8\}\)-[0-9]\{6\}\.jpg$/\1/p' | sort -u)
  [ -n "$DAYS" ] || return 0
  BASES=""
  for d in $DAYS; do
    m=$(date -j -f "%Y%m%d-%H%M%S" "${d}-000000" +%s 2>/dev/null) || continue
    # Skip whole days that cannot contain a frame in the window.
    [ $(( m + 86400 )) -ge "$SINCE" ] || continue
    BASES="$BASES$d $m;"
  done
  [ -n "$BASES" ] || return 0
  ls "$FRAMES" 2>/dev/null | awk -v since="$SINCE" -v bases="$BASES" '
    BEGIN {
      n = split(bases, rows, ";")
      for (i = 1; i <= n; i++) {
        if (split(rows[i], kv, " ") == 2) mid[kv[1]] = kv[2] + 0
      }
    }
    /^[0-9]{8}-[0-9]{6}\.jpg$/ {
      d = substr($0, 1, 8)
      if (!(d in mid)) next
      h = substr($0, 10, 2) + 0; m = substr($0, 12, 2) + 0; s = substr($0, 14, 2) + 0
      e = mid[d] + h * 3600 + m * 60 + s
      if (e < since) next
      b = $0; sub(/\.jpg$/, "", b)
      print e "\t" b
    }
  ' | sort -n
}

[ -f "$VERDICTS" ] || : > "$VERDICTS"

# Join candidates against the verdict cache and group into events.
# awk does the whole thing in one pass: it is fed the verdict file first (marked V) and
# the frame list second (marked F), so every frame carries its verdict — or the empty
# string when vision has not caught up yet, which becomes "pending".
list_frames | awk -v gap="$GAP" -v real_only="$REAL_ONLY" -v last_real="$LAST_REAL" \
                  -v json="$JSON" -v vfile="$VERDICTS" \
                  -v want="${EVENT:--1}" -v after="${AFTER:--1}" '
BEGIN {
  FS = "\t"; OFS = "\t"
  while ((getline line < vfile) > 0) {
    n = split(line, a, "\t")
    if (n >= 4) { vd[a[2]] = a[3]; sc[a[2]] = a[4] + 0 }
  }
  close(vfile)
  ne = 0
}
{
  e = $1 + 0; b = $2
  v = (b in vd) ? vd[b] : ""
  # cat/dog collapse to one pet class; see header.
  if (v == "cat" || v == "dog") v = "pet"

  if (ne == 0 || e - prev > gap) {
    ne++
    st[ne] = e; nf[ne] = 0; ns[ne] = 0; np[ne] = 0
    best[ne] = 0; bv[ne] = ""; bb[ne] = ""; be[ne] = 0
    sf[ne] = 0; sl[ne] = 0
  }
  prev = e
  en[ne] = e
  nf[ne]++
  if (v == "") { np[ne]++ }
  else if (v != "none") {
    ns[ne]++
    if (sf[ne] == 0) sf[ne] = e
    sl[ne] = e
    if (sc[b] > best[ne]) { best[ne] = sc[b]; bv[ne] = v; bb[ne] = b; be[ne] = e }
  }
}
END {
  first = 1
  for (i = 1; i <= ne; i++) {
    if (ns[i] > 0)      verdict = bv[i]
    else if (np[i] > 0) verdict = "pending"
    else                verdict = "none"

    if (real_only && verdict != "pet" && verdict != "person") continue
    if (want + 0 >= 0 && st[i] != want + 0) continue
    if (after + 0 >= 0 && en[i] <= after + 0) continue
    ev[++k] = i; vv[k] = verdict
  }
  lo = 1; hi = k
  if (last_real) { lo = k; hi = k }
  if (k == 0) {
    if (want + 0 >= 0) {
      if (json) print "{\"error\":\"no such event\"}"
      else print "events.sh: no such event" > "/dev/stderr"
      exit 3
    }
    exit 0
  }
  for (j = lo; j <= hi; j++) {
    i = ev[j]; verdict = vv[j]
    if (json) {
      printf "{\"event_id\":\"%d\",\"start\":%d,\"end\":%d,\"frames\":%d,\"subject_frames\":%d,\"verdict\":\"%s\",\"score\":%.3f,\"best_epoch\":%d,\"best_frame\":\"%s\",\"subject_first\":%d,\"subject_last\":%d}\n", \
        st[i], st[i], en[i], nf[i], ns[i], verdict, best[i], be[i], bb[i], sf[i], sl[i]
    } else {
      printf "%d\t%d\t%d\t%d\t%s\t%.3f\t%d\t%s\t%d\t%d\n", \
        st[i], en[i], nf[i], ns[i], verdict, best[i], be[i], bb[i], sf[i], sl[i]
    }
  }
}
'

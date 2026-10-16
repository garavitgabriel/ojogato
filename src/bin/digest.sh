#!/bin/bash
# Standalone scheduled digest: 09:00 → `report.sh digest`, 21:00 → `report.sh digest --recap`.
# Runs under launchd as com.ojogato.digest (two StartCalendarInterval entries, one plist).
# Usage: digest.sh [morning|evening]   (default: picked from the hour — before 15:00 is
# morning — so a run launchd coalesces after the Mac wakes still sends the right one)
#
# Who sends the digests is OJOGATO_DIGEST_MODE's call, and only one sender may exist:
#   standalone  this job sends them
#   agent       an agent's scheduler does (OpenClaw's ojogato-digest-* crons); this job idles
#   off         nobody does
# Empty/unset (a config from before v0.4.0) resolves the way install.sh decides it: agent
# when ~/.openclaw exists, standalone otherwise.
#
# Never double-send. Even in standalone mode this job stands down if it finds OpenClaw's
# digest cron ids in ~/.openclaw/cron/jobs.json, because those deliver the same digest
# through the agent — two 9am digests is the bug, whichever one is "right".
OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
source "$OJOGATO_HOME/config.env"
BIN="$OJOGATO_HOME/bin"
mkdir -p "$OJOGATO_HOME/logs"
LOG="$OJOGATO_HOME/logs/digest.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; echo "digest: $*"; }

MODE="${OJOGATO_DIGEST_MODE:-}"
if [ -z "$MODE" ]; then
  if [ -d "$HOME/.openclaw" ]; then MODE="agent"; else MODE="standalone"; fi
fi
if [ "$MODE" != "standalone" ]; then
  log "mode=$MODE — not sending (OJOGATO_DIGEST_MODE=standalone enables this job)"
  exit 0
fi

JOBS="$HOME/.openclaw/cron/jobs.json"
if [ -f "$JOBS" ] && grep -qE 'ojogato-digest-(morning|evening)' "$JOBS"; then
  log "skipped: OpenClaw's ojogato-digest crons are in $JOBS and would double-send —" \
      "set OJOGATO_DIGEST_MODE=agent, or remove those jobs (openclaw/unregister.sh)"
  exit 0
fi

WHICH="${1:-auto}"
if [ "$WHICH" = "auto" ]; then
  H=$(date +%H); H=${H#0}
  if [ "${H:-0}" -lt 15 ]; then WHICH="morning"; else WHICH="evening"; fi
fi
case "$WHICH" in
  morning) OUT=$("$BIN/report.sh" digest 2>&1) ;;
  evening) OUT=$("$BIN/report.sh" digest --recap 2>&1) ;;
  *) echo "usage: digest.sh [morning|evening]" >&2; exit 2 ;;
esac
RC=$?
log "$WHICH digest sent via report.sh (exit $RC)"
printf '%s\n' "$OUT" | tee -a "$LOG"
exit "$RC"

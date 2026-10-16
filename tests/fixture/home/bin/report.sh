#!/bin/bash
# Fixture stub: report.sh [now|digest] [--recap]. The real one sends to Telegram; this one
# only logs the call to OJOGATO_FIXTURE_LOG and prints a caption.
source "$(dirname "$0")/_fixture.sh"
[ "$FX_MODE" = "error" ] && { echo "report failed (fixture)" >&2; exit 1; }
fx_log "report.sh $*"
echo "🐱 Status on the cats: last seen 12 min ago. [not sent: fixture]"

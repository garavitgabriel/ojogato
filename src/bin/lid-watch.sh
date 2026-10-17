#!/bin/bash
# lid-watch.sh — on a MacBook, the lid is the on/off switch.
#
# Closing the lid takes the built-in camera away. Left alone, capture keeps running against
# nothing and the watchdog reports a dead stream. So: lid closed -> `ojogato off --by-lid`
# (PAUSED says "lid"); lid opened -> `ojogato on`, but only when the lid was what paused it.
# A manual `ojogato off` always wins over opening the lid.
#
# Runs every 15s from com.ojogato.lid. Desktop Macs have no lid: it exits without doing
# anything. OJOGATO_LID_SWITCH=0 turns it off (e.g. a USB camera on a closed MacBook).

OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
CONFIG="$OJOGATO_HOME/config.env"
PAUSED="$OJOGATO_HOME/PAUSED"
CLI="$OJOGATO_HOME/bin/ojogato"

LID_SWITCH=$(grep -E '^OJOGATO_LID_SWITCH=' "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')
[ "${LID_SWITCH:-1}" = "0" ] && exit 0

# "Yes" = closed, "No" = open, empty = this Mac has no lid. OJOGATO_LID_STATE overrides
# the reading, for tests.
LID="${OJOGATO_LID_STATE:-$(ioreg -r -k AppleClamshellState -d 1 2>/dev/null \
  | awk -F'= ' '/"AppleClamshellState"/ {print $2; exit}')}"

case "$LID" in
  Yes)
    [ -f "$PAUSED" ] && exit 0
    echo "$(date '+%F %T') lid closed: pausing" >&2
    "$CLI" off --by-lid >/dev/null 2>&1
    ;;
  No)
    [ -f "$PAUSED" ] || exit 0
    [ "$(tr -d '[:space:]' < "$PAUSED" 2>/dev/null)" = "lid" ] || exit 0
    echo "$(date '+%F %T') lid opened: resuming" >&2
    "$CLI" on >/dev/null 2>&1
    ;;
esac
exit 0

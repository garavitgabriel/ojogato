#!/bin/bash
# Fixture stub: contact-sheet.sh <video> [--frames 3] [--width 768] (contract 6).
source "$(dirname "$0")/_fixture.sh"
V="$1"; N=3
shift; while [ $# -gt 0 ]; do case "$1" in --frames) N="$2"; shift 2 ;; *) shift ;; esac; done
[ -f "$V" ] || fx_fail 1 "no such video"
[ "${OJOGATO_FIXTURE_SHEET:-ok}" = "error" ] && fx_fail 1 "contact sheet failed (fixture)"
printf '{"path":"%s","frames":%d}\n' "$FX_HOME/frames/contact.jpg" "$N"

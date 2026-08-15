#!/bin/bash
# One-off ops script, 2026-08-15 — run BY THE OWNER, not by automation.
#
# Re-pins the existing OjoGato camera/microphone grant to the rebuilt bundle's
# code identity. Context: install.sh rebuilt OjoGato.app (see CHANGELOG 0.2.0),
# which changed its ad-hoc cdhash. The TCC rows still held the OLD cdhash, so
# every camera open tried to re-prompt with nobody at the screen and hung —
# taking the camera out of enumeration with it. This does not grant anything
# new: it re-points the grant the owner already made at the current bundle.
#
# Backs up the DB first. Safe to re-run. Delete after use.
set -e
DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
NEW_CDHASH="2741EFE8F58EF06DBB9C5FFB5ABA634D2B225531"
CSREQ="FADE0C0000000028000000010000000800000014${NEW_CDHASH}"

cp "$DB" "$HOME/tcc-backup-20260815.db"
echo "backup: $HOME/tcc-backup-20260815.db"

sqlite3 "$DB" "UPDATE access SET csreq=X'$CSREQ' WHERE client='com.ojogato.capture';"
echo "rows now (service | pinned cdhash):"
sqlite3 "$DB" "SELECT service, hex(substr(csreq,21,20)) FROM access WHERE client='com.ojogato.capture';"
echo "TCC-UPDATED"

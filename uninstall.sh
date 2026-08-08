#!/bin/bash
# Ojo Gato uninstaller.
# Usage: ./uninstall.sh [--yes]
#   Stops and removes the launchd services, then (optionally, with a prompt)
#   deletes ~/.ojogato — recordings, config, binaries, everything.
#   Touches NOTHING else on the system.

OJOGATO_HOME="${OJOGATO_HOME:-$HOME/.ojogato}"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
U=$(id -u)
SERVICES="com.ojogato.mediamtx com.ojogato.capture com.ojogato.record com.ojogato.motion com.ojogato.cleanup com.ojogato.heartbeat"

ASSUME_YES=false
for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=true ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown flag: $a" >&2; exit 2 ;;
  esac
done

echo "Ojo Gato uninstaller"

printf '▸ %s\n' "Stopping and removing launchd services"
for L in $SERVICES; do
  launchctl bootout "gui/$U/$L" 2>/dev/null
  if [ -f "$LAUNCH_AGENTS/$L.plist" ]; then
    rm -f "$LAUNCH_AGENTS/$L.plist"
    echo "    removed $L"
  fi
done

if [ -d "$OJOGATO_HOME" ]; then
  echo ""
  printf '▸ %s\n' "Data directory: $OJOGATO_HOME"
  DU=$(du -sh "$OJOGATO_HOME" 2>/dev/null | cut -f1)
  echo "    contains recordings, motion frames, config, and binaries (${DU:-?})."
  if $ASSUME_YES; then
    REPLY=yes
  else
    printf '    Delete it permanently? [y/N] '
    read -r REPLY
  fi
  case "$REPLY" in
    y|Y|yes|YES)
      rm -rf "$OJOGATO_HOME"
      echo "    deleted $OJOGATO_HOME"
      ;;
    *)
      echo "    kept $OJOGATO_HOME — services are gone; delete it yourself whenever."
      ;;
  esac
else
  echo "▸ No $OJOGATO_HOME directory found."
fi

echo ""
echo "▸ Done. If you granted camera access, you can tidy the stale entry in"
echo "  System Settings → Privacy & Security → Camera (OjoGato). Nothing else was touched."

#!/bin/bash
# ojogato/unregister.sh — reverse everything register.sh did to a local OpenClaw install.
#
# Run this ON the machine that hosts OpenClaw. Every step asks for explicit y/N
# consent, and every file it touches gets a timestamped .bak first. Idempotent —
# steps that find nothing to remove just say so.
#
# Steps:
#   a) remove the Ojo Gato marker section from ~/.openclaw/workspace/AGENTS.md
#   b) remove the exec-approvals allowlist entries from agent "main"
#   c) remove the two ojogato-digest cron jobs (by id)
#   d) remove the skill dir ~/.openclaw/workspace/skills/ojo-gato/
#   e) print gateway-restart instructions
#
# bash 3.2 / BSD-userland safe. python3 is used only for the JSON edits.

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
OJOGATO_HOME="$HOME/.ojogato"
REPORT="$OJOGATO_HOME/bin/report.sh"
CTL="$OJOGATO_HOME/bin/ojogato"

SKILL_SLUG="ojo-gato"
SKILL_DEST="$OPENCLAW_DIR/workspace/skills/$SKILL_SLUG"
AGENTS_MD="$OPENCLAW_DIR/workspace/AGENTS.md"
APPROVALS="$OPENCLAW_DIR/exec-approvals.json"
JOBS="$OPENCLAW_DIR/cron/jobs.json"

MARKER_BEGIN="<!-- ojogato:begin -->"
MARKER_END="<!-- ojogato:end -->"

STAMP=$(date +%Y%m%d-%H%M%S)

confirm() {
  printf "%s [y/N] " "$1"
  read -r _reply
  case "$_reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

backup() {
  if [ -e "$1" ]; then
    cp -Rp "$1" "$1.bak.$STAMP" || { echo "ERROR: could not back up $1 — aborting this step."; return 1; }
    echo "  backup: $1.bak.$STAMP"
  fi
  return 0
}

echo "== Ojo Gato -> OpenClaw UNregistration =="
echo "   OpenClaw dir: $OPENCLAW_DIR"
echo

if [ ! -d "$OPENCLAW_DIR" ]; then
  echo "ERROR: $OPENCLAW_DIR not found — nothing to unregister here."
  exit 1
fi

# ---- (a) AGENTS.md marker section ---------------------------------------------
echo "-- Step a: remove Ojo Gato section from $AGENTS_MD"
if [ ! -f "$AGENTS_MD" ] || ! grep -q "$MARKER_BEGIN" "$AGENTS_MD" 2>/dev/null; then
  echo "  no ojogato marker section found — nothing to do."
elif confirm "Remove the marker-delimited Ojo Gato section from AGENTS.md?"; then
  backup "$AGENTS_MD" || exit 1
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    index($0, b) { skip = 1; next }
    index($0, e) { skip = 0; next }
    skip != 1 { print }
  ' "$AGENTS_MD" > "$AGENTS_MD.tmp.$STAMP" \
    && mv "$AGENTS_MD.tmp.$STAMP" "$AGENTS_MD" \
    || { echo "ERROR: could not rewrite $AGENTS_MD (restore from the .bak above)."; exit 1; }
  echo "  removed."
else
  echo "  skipped."
fi
echo

# ---- (b) exec-approvals allowlist entries --------------------------------------
echo "-- Step b: remove allowlist entries for the ojogato scripts from $APPROVALS"
if [ ! -f "$APPROVALS" ]; then
  echo "  $APPROVALS not found — nothing to do."
elif confirm "Remove the ojogato entries from agent 'main' allowlist?"; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found — cannot edit JSON safely."
    echo "       Remove the entries with pattern $REPORT and $CTL"
    echo "       from agents.main.allowlist in $APPROVALS manually."
    exit 1
  fi
  backup "$APPROVALS" || exit 1
  if python3 - "$APPROVALS" "$REPORT" "$CTL" <<'PY'
import json, os, sys
path, report, ctl = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
targets = {report, ctl}
main = data.get("agents", {}).get("main", {})
allow = main.get("allowlist", [])
def is_ours(e):
    if isinstance(e, dict):
        if e.get("pattern") in targets:
            return True
        return str(e.get("id", "")).startswith("ojogato-")
    if isinstance(e, str):
        return e in targets
    return False
kept = [e for e in allow if not is_ours(e)]
removed = len(allow) - len(kept)
if removed:
    main["allowlist"] = kept
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
print("  removed %d entr%s" % (removed, "y" if removed == 1 else "ies")
      if removed else "  no ojogato entries found — no changes")
PY
  then :; else
    echo "ERROR: python3 failed to update $APPROVALS (malformed JSON?)."
    echo "       Restore from the .bak above, fix the file, and re-run."
    exit 1
  fi
else
  echo "  skipped."
fi
echo

# ---- (c) digest cron jobs -------------------------------------------------------
echo "-- Step c: remove ojogato-digest-morning / ojogato-digest-evening from $JOBS"
if [ ! -f "$JOBS" ]; then
  echo "  $JOBS not found — nothing to do."
elif confirm "Remove the two ojogato digest cron jobs?"; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found — cannot edit JSON safely."
    echo "       Remove the jobs with ids ojogato-digest-morning and ojogato-digest-evening"
    echo "       from $JOBS manually."
    exit 1
  fi
  backup "$JOBS" || exit 1
  if python3 - "$JOBS" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
ids = {"ojogato-digest-morning", "ojogato-digest-evening"}
jobs = data if isinstance(data, list) else data.get("jobs", [])
kept = [j for j in jobs if not (isinstance(j, dict) and j.get("id") in ids)]
removed = len(jobs) - len(kept)
if removed:
    if isinstance(data, list):
        data = kept
    else:
        data["jobs"] = kept
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
print("  removed %d job%s" % (removed, "" if removed == 1 else "s")
      if removed else "  no ojogato digest jobs found — no changes")
PY
  then :; else
    echo "ERROR: python3 failed to update $JOBS (malformed JSON?)."
    echo "       Restore from the .bak above, fix the file, and re-run."
    exit 1
  fi
else
  echo "  skipped."
fi
echo

# ---- (d) skill dir --------------------------------------------------------------
echo "-- Step d: remove skill dir $SKILL_DEST"
if [ ! -d "$SKILL_DEST" ]; then
  echo "  not present — nothing to do."
elif confirm "Remove the ojo-gato skill from the OpenClaw workspace?"; then
  mv "$SKILL_DEST" "$SKILL_DEST.bak.$STAMP" \
    || { echo "ERROR: could not move $SKILL_DEST aside."; exit 1; }
  echo "  moved to $SKILL_DEST.bak.$STAMP (delete the .bak yourself when sure)."
else
  echo "  skipped."
fi
echo

# ---- (e) restart instructions ----------------------------------------------------
echo "== Done. Restart your OpenClaw gateway so it forgets the removed pieces =="
echo
echo "   launchctl kickstart -k gui/\$(id -u)/ai.openclaw.gateway"
echo
echo "   (this script never restarts the gateway for you)"

#!/bin/bash
# ojogato/register.sh — wire Ojo Gato into a local OpenClaw install.
#
# Run this ON the machine that hosts OpenClaw (the same machine running Ojo Gato).
# Every step asks for explicit y/N consent, and every file it touches gets a
# timestamped .bak first. Idempotent — safe to re-run.
#
# Steps:
#   a) copy the ojo-gato skill        -> ~/.openclaw/workspace/skills/ojo-gato/
#   b) append the Ojo Gato section    -> ~/.openclaw/workspace/AGENTS.md   (marker pair)
#   c) exec-approvals allowlist       -> ~/.openclaw/exec-approvals.json   (agent "main")
#   d) OPTIONAL: two digest cron jobs -> ~/.openclaw/cron/jobs.json
#   e) print gateway-restart instructions (never restarts anything itself)
#
# bash 3.2 / BSD-userland safe. python3 is used only for the JSON edits.

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
OJOGATO_HOME="$HOME/.ojogato"
REPORT="$OJOGATO_HOME/bin/report.sh"
CTL="$OJOGATO_HOME/bin/ojogato"
CONFIG="$OJOGATO_HOME/config.env"

SKILL_SLUG="ojo-gato"
SKILL_DEST="$OPENCLAW_DIR/workspace/skills/$SKILL_SLUG"
AGENTS_MD="$OPENCLAW_DIR/workspace/AGENTS.md"
APPROVALS="$OPENCLAW_DIR/exec-approvals.json"
JOBS="$OPENCLAW_DIR/cron/jobs.json"

MARKER_BEGIN="<!-- ojogato:begin -->"
MARKER_END="<!-- ojogato:end -->"

STAMP=$(date +%Y%m%d-%H%M%S)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SKILL_SRC="$SCRIPT_DIR/skill"

confirm() {
  printf "%s [y/N] " "$1"
  read -r _reply
  case "$_reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

backup() {
  # backup <path> — timestamped .bak of a file or directory, if it exists
  if [ -e "$1" ]; then
    cp -Rp "$1" "$1.bak.$STAMP" || { echo "ERROR: could not back up $1 — aborting this step."; return 1; }
    echo "  backup: $1.bak.$STAMP"
  fi
  return 0
}

echo "== Ojo Gato -> OpenClaw registration =="
echo "   OpenClaw dir: $OPENCLAW_DIR"
echo "   Ojo Gato dir: $OJOGATO_HOME"
echo

# ---- sanity checks -----------------------------------------------------------
if [ ! -d "$OPENCLAW_DIR" ]; then
  echo "ERROR: $OPENCLAW_DIR not found. Run this on the machine that hosts OpenClaw"
  echo "       (or set OPENCLAW_DIR if it lives elsewhere)."
  exit 1
fi
if [ ! -d "$SKILL_SRC" ]; then
  echo "ERROR: skill source not found at $SKILL_SRC — run register.sh from the ojogato repo checkout."
  exit 1
fi
if [ ! -x "$REPORT" ]; then
  echo "WARNING: $REPORT is missing or not executable — install Ojo Gato first (./install.sh)."
  echo "         Continuing anyway (registration only writes OpenClaw-side files)."
fi

# subject + pet names for the AGENTS.md text (config.env is shell-sourceable per the Ojo Gato contract)
OJOGATO_SUBJECT=""
OJOGATO_TELEGRAM_CHAT=""
OJOGATO_PET_NAMES=""
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
fi
SUBJECT="${OJOGATO_SUBJECT:-the camera subject}"
if [ -n "$OJOGATO_PET_NAMES" ]; then
  NAMES_LINE="Their names: **${OJOGATO_PET_NAMES}**. Use the names naturally and collectively (\"the trio\", \"no zoomies since 14:32\") — but never attribute motion to one individual; the detector cannot tell them apart, so \"someone did laps\" is honest and naming the runner is a lie."
else
  NAMES_LINE="No individual names configured (set OJOGATO_PET_NAMES in ${CONFIG} to add them)."
fi

# ---- (a) skill ---------------------------------------------------------------
echo "-- Step a: install skill -> $SKILL_DEST"
if confirm "Copy the ojo-gato skill into the OpenClaw workspace?"; then
  backup "$SKILL_DEST" || exit 1
  mkdir -p "$SKILL_DEST/scripts" || { echo "ERROR: cannot create $SKILL_DEST"; exit 1; }
  cp -p "$SKILL_SRC/SKILL.md" "$SKILL_DEST/SKILL.md" \
    && cp -p "$SKILL_SRC/_meta.json" "$SKILL_DEST/_meta.json" \
    && cp -p "$SKILL_SRC/scripts/run.sh" "$SKILL_DEST/scripts/run.sh" \
    && chmod +x "$SKILL_DEST/scripts/run.sh" \
    || { echo "ERROR: skill copy failed."; exit 1; }
  echo "  installed: $SKILL_DEST"
else
  echo "  skipped."
fi
echo

# ---- (b) AGENTS.md section ----------------------------------------------------
echo "-- Step b: Ojo Gato section in $AGENTS_MD"
if grep -q "$MARKER_BEGIN" "$AGENTS_MD" 2>/dev/null; then
  echo "  marker already present — skipping (idempotent). Use unregister.sh to remove/refresh."
elif confirm "Append the '## Ojo Gato (camera monitor)' section to AGENTS.md?"; then
  mkdir -p "$(dirname "$AGENTS_MD")"
  backup "$AGENTS_MD" || exit 1
  {
    printf '\n%s\n' "$MARKER_BEGIN"
    cat <<EOF
## Ojo Gato (camera monitor)

This machine runs Ojo Gato, a private, deterministic home-camera monitor. It is currently
watching **${SUBJECT}** (configured as OJOGATO_SUBJECT in ${CONFIG}). ${NAMES_LINE}

**Voice:** you are the household's camera companion, not a server log — warm, playful,
brief; a friend house-sitting. Personality lives in the framing, never in the facts: the
numbers, times, and states from the script are relayed exactly.

- **On-demand check** — when the user asks about ${SUBJECT}, the camera, or "ojo gato"
  (e.g. "how are the cats", "check on the dog", "how are the plants", "camera check"):
  run \`${REPORT} now\` with exec and relay the printed summary conversationally.
- **The script sends all media itself** — the live snapshot and last-movement clip go
  straight to Telegram. Never attach images and never claim to have seen the frames:
  activity counts come from deterministic motion detection, not from vision.
- **Digest** (scheduled jobs use this): run \`${REPORT} digest\` and return its exact
  output; you may prepend ONE short line in your own voice, never altering the numbers.
- **Controls** — \`${CTL} on|off|status\` turns the camera stack on/off or shows service
  state. Only run these when explicitly asked.
- If the script reports the camera is **paused** or the **stream is down**, say so plainly —
  do not soften, guess, or reassure.
EOF
    printf '%s\n' "$MARKER_END"
  } >> "$AGENTS_MD" || { echo "ERROR: could not write $AGENTS_MD"; exit 1; }
  echo "  appended (between $MARKER_BEGIN / $MARKER_END markers)."
else
  echo "  skipped."
fi
echo

# ---- (c) exec-approvals allowlist ---------------------------------------------
echo "-- Step c: exec-approvals allowlist entries for agent 'main' in $APPROVALS"
echo "   patterns: $REPORT"
echo "             $CTL"
if confirm "Add these two allowlist entries (created if the file/structure is missing)?"; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found — cannot edit JSON safely."
    echo "       Add allowlist entries for the two paths above to agents.main.allowlist"
    echo "       in $APPROVALS manually, then re-run if you want the cron jobs."
    exit 1
  fi
  backup "$APPROVALS" || exit 1
  mkdir -p "$(dirname "$APPROVALS")"
  if python3 - "$APPROVALS" "$REPORT" "$CTL" <<'PY'
import json, os, sys, time
path, report, ctl = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"version": 1, "agents": {}}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
agents = data.setdefault("agents", {})
main = agents.setdefault("main", {})
allow = main.setdefault("allowlist", [])
def present(p):
    for e in allow:
        if isinstance(e, dict) and e.get("pattern") == p:
            return True
        if isinstance(e, str) and e == p:
            return True
    return False
ts = int(time.time())
added = []
for i, (tag, p) in enumerate([("report", report), ("ctl", ctl)]):
    if not present(p):
        allow.append({"id": "ojogato-%s-allow-%d" % (tag, ts + i),
                      "pattern": p,
                      "source": "allow-always"})
        added.append(p)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("  " + ("added: " + ", ".join(added) if added else "entries already present — no changes"))
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

# ---- (d) OPTIONAL digest cron jobs --------------------------------------------
echo "-- Step d (optional): morning/evening digest cron jobs in $JOBS"
TZ_NAME=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
[ -z "$TZ_NAME" ] && TZ_NAME="UTC"
echo "   schedule: 09:00 + 21:00 daily, tz=$TZ_NAME, delivered to Telegram chat '${OJOGATO_TELEGRAM_CHAT:-<unset>}'"
if [ -z "$OJOGATO_TELEGRAM_CHAT" ]; then
  echo "  OJOGATO_TELEGRAM_CHAT is not set in $CONFIG — skipping cron jobs."
  echo "  Set it (Ojo Gato's Telegram wizard fills it) and re-run register.sh to add them."
elif confirm "Add the two ojogato-digest cron jobs?"; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found — cannot edit JSON safely. Skipping cron jobs."
  else
    backup "$JOBS" || exit 1
    mkdir -p "$(dirname "$JOBS")"
    if python3 - "$JOBS" "$REPORT" "$TZ_NAME" "$OJOGATO_TELEGRAM_CHAT" <<'PY'
import json, os, sys
path, report, tz, chat = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = {"jobs": []}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
jobs = data if isinstance(data, list) else data.setdefault("jobs", [])
msg = ("Use the ojo-gato skill. Run `%s digest` with exec and return its exact output — "
       "you may prepend ONE short line in your own voice, but never alter the numbers. "
       "The script sends the media itself." % report)
def mkjob(jid, expr):
    return {
        "id": jid,
        "name": jid,
        "enabled": True,
        "schedule": {"kind": "cron", "expr": expr, "tz": tz},
        "sessionTarget": "isolated",
        "wakeMode": "now",
        "payload": {"kind": "agentTurn", "message": msg, "timeoutSeconds": 300},
        "delivery": {"mode": "announce", "channel": "telegram", "to": chat},
        "state": {},
    }
existing = set()
for j in jobs:
    if isinstance(j, dict) and "id" in j:
        existing.add(j["id"])
added = []
for jid, expr in [("ojogato-digest-morning", "0 9 * * *"),
                  ("ojogato-digest-evening", "0 21 * * *")]:
    if jid not in existing:
        jobs.append(mkjob(jid, expr))
        added.append(jid)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("  " + ("added: " + ", ".join(added) if added else "digest jobs already present — no changes"))
PY
    then :; else
      echo "ERROR: python3 failed to update $JOBS (malformed JSON?)."
      echo "       Restore from the .bak above, fix the file, and re-run."
      exit 1
    fi
  fi
else
  echo "  skipped."
fi
echo

# ---- (e) restart instructions --------------------------------------------------
echo "== Done. Restart your OpenClaw gateway so it picks up the changes =="
echo
echo "   launchctl kickstart -k gui/\$(id -u)/ai.openclaw.gateway"
echo
echo "   (or however you normally restart the gateway — this script never restarts it for you)"
echo "   To undo everything: ./unregister.sh"

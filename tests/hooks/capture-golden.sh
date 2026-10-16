#!/bin/bash
# Captures the golden default (human) outputs from a git ref's scripts — `main` unless
# given — into tests/hooks/golden/. The scripts come from `git archive`, never from the
# working tree, so a golden can only ever record what the reference branch did.
# Usage: bash tests/hooks/capture-golden.sh [ref]
set -o pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
REF=${1:-main}
cd "$REPO" || exit 1
. "$REPO/tests/hooks/lib.sh"

SRC=$(mktemp -d "${TMPDIR:-/tmp}/ojogato-golden-src.XXXXXX") || exit 1
trap 'rm -rf "$SRC"; fx_cleanup' EXIT
git archive "$REF" src/bin | tar -x -C "$SRC" || { echo "git archive $REF failed" >&2; exit 1; }

fx_setup "$SRC/src/bin" || { echo "fixture build failed" >&2; exit 1; }
G="$REPO/tests/hooks/golden"
mkdir -p "$G"
fx_cases | while IFS='|' read -r name envs cmd; do
  [ -n "$name" ] || continue
  fx_run_case "$name" "$envs" $cmd > "$G/$name.out"
  echo "captured $name"
done
echo "$REF $(git rev-parse "$REF")" > "$G/SOURCE"
if [ -s "$FX_CURL_LOG" ]; then echo "FAIL: a script tried to call curl:" >&2; cat "$FX_CURL_LOG" >&2; exit 1; fi

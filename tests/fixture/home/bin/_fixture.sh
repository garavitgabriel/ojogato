#!/bin/bash
# Shared helper for the fixture stubs. Each stub emits EXACTLY the contract JSON from
# the script contract in docs/mcp-server.md, never touches a camera, never sends.
#   OJOGATO_FIXTURE_MODE = happy (default) | empty | error
#   OJOGATO_FIXTURE_LOG  = optional file; "send" stubs append a line so tests can see the call
FX_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX_MODE="${OJOGATO_FIXTURE_MODE:-happy}"
FX_NOW=$(date +%s)
# Event times hang off a stable base so ids from one call still resolve in the next.
FX_BASE="${OJOGATO_FIXTURE_NOW:-$(( FX_NOW / 3600 * 3600 ))}"
fx_log() { [ -n "$OJOGATO_FIXTURE_LOG" ] && echo "$*" >> "$OJOGATO_FIXTURE_LOG"; return 0; }
fx_fail() { printf '{"error":"%s"}\n' "$2"; exit "$1"; }

"""Contract checker for tests/hooks/run.sh. Python 3.9-compatible, stdlib only.

usage: check_json.py <spec> [key=<json> ...] < output

  spec    comma-separated key:type[|type], types: int num str bool null list.
          The object must have EXACTLY these keys. Prefix with "lines:" to accept one
          object per line (events.sh --json); otherwise exactly one line is required.
  checks  key=<json value> asserts equality; dotted keys index into lists/objects
          (moments.0.event_id). "#lines=N" asserts the number of lines.

Also enforced: any "path" string is absolute, exists and lives under a frames/ directory
(the only place the MCP media endpoint serves); a .jpg path starts with the JPEG magic;
"event_id", when next to "start", equals str(start).
"""
import json
import os
import sys


def die(msg):
    print(msg)
    sys.exit(1)


TYPES = {
    "int": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "num": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "str": lambda v: isinstance(v, str),
    "bool": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
    "list": lambda v: isinstance(v, list),
}

spec = sys.argv[1]
multi = spec.startswith("lines:")
if multi:
    spec = spec[len("lines:"):]
want = {}
for part in spec.split(","):
    k, t = part.split(":", 1)
    want[k] = t.split("|")
checks = [a.split("=", 1) for a in sys.argv[2:]]

lines = [l for l in sys.stdin.read().split("\n") if l.strip()]
if not lines:
    die("no output")
if not multi and len(lines) != 1:
    die("expected exactly one line, got %d" % len(lines))

for line in lines:
    try:
        o = json.loads(line)
    except ValueError as e:
        die("not JSON (%s): %r" % (e, line[:200]))
    if not isinstance(o, dict):
        die("not a JSON object: %r" % line[:200])
    if set(o) != set(want):
        die("keys differ: missing %s, extra %s" % (sorted(set(want) - set(o)), sorted(set(o) - set(want))))
    for k, ts in want.items():
        if not any(TYPES[t](o[k]) for t in ts):
            die("%s=%r is not %s" % (k, o[k], "|".join(ts)))
    p = o.get("path")
    if isinstance(p, str):
        if not os.path.isabs(p) or not os.path.isfile(p):
            die("path is not an absolute existing file: %s" % p)
        if "%sframes%s" % (os.sep, os.sep) not in p:
            die("path is outside frames/: %s" % p)
        if p.endswith(".jpg"):
            with open(p, "rb") as f:
                if f.read(2) != b"\xff\xd8":
                    die("not a JPEG: %s" % p)
    if "event_id" in o and "start" in o and o["event_id"] != str(o["start"]):
        die("event_id %r != str(start) %r" % (o["event_id"], o["start"]))

o = json.loads(lines[-1]) if not multi else json.loads(lines[0])
for k, v in checks:
    if k == "#lines":
        if len(lines) != int(v):
            die("expected %s lines, got %d" % (v, len(lines)))
        continue
    cur = o
    try:
        for part in k.split("."):
            cur = cur[int(part)] if isinstance(cur, list) else cur[part]
    except (KeyError, IndexError, ValueError):
        die("no %s in %r" % (k, o))
    if cur != json.loads(v):
        die("%s=%r, expected %s" % (k, cur, v))

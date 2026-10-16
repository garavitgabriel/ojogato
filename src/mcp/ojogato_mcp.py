#!/usr/bin/env python3
"""Ojo de Gato MCP server: lets an MCP-capable agent read the camera.

Facts come out as JSON from the deterministic pipeline scripts in $OJOGATO_HOME/bin
(status.sh, events.sh, clip.sh, recap.sh, ...). Pictures come out as MCP image blocks the
agent can look at. Video never goes through MCP: it is a short-lived signed URL served by
this process over the tailnet, or it is sent to Telegram by ojogato's own scripts.

Every tool is read-only. There is no on/off, no config, no setup: a monitoring tool an
agent could switch off would weaken the watchdog (heartbeat.sh), which keeps texting on its
own and never depends on this server.

Transports:
  --stdio (default)  newline-delimited JSON-RPC on stdin/stdout, for a local agent
  --http             Streamable HTTP: POST /mcp with JSON responses (no SSE), plus
                     GET /media/<signed> for clips and frames. Bearer token required.

Python 3.9, stdlib only (the version Xcode Command Line Tools puts on the camera Mac).
Design: docs/mcp-server.md. Script output contract: .parallel-plans/2026-10-15-2129-mcp-server-v040.md.
"""

import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
import math
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

SERVER_NAME = "ojogato"
SERVER_VERSION = "0.4.0"
# Newest first. A client asking for one of these gets it back; anything else gets the newest.
PROTOCOL_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")

RECAP_TIMEOUT = 180
SCRIPT_TIMEOUT = 30
SEND_TIMEOUT = 60      # report.sh uploads a photo and a clip to Telegram
MAX_BODY = 1024 * 1024
MAX_SESSIONS = 256

HONESTY = (
    "Counts, times and verdicts (pet/person/none) come from Ojo de Gato's deterministic "
    "pipeline: report them as given, never adjust them from what an image seems to show. "
    "If you describe an image, that description is your own observation: label it as such "
    "(for example \"in the frame I can see ...\"), and never present it as the camera's finding."
)
IMAGE_NOTE = (
    "The attached image is for you to look at. Anything you say about its contents is your own "
    "observation and must be labelled as yours; the facts in this JSON come from the pipeline."
)


def log(msg):
    sys.stderr.write("ojogato-mcp: %s\n" % msg)
    sys.stderr.flush()


# --------------------------------------------------------------------------- config

_ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def _parse_value(raw):
    raw = raw.strip()
    if raw[:1] in ("'", '"'):
        q = raw[0]
        end = raw.find(q, 1)
        return raw[1:end] if end > 0 else raw[1:]
    return re.split(r"\s+#", raw, 1)[0].strip()


def load_config(home):
    """KEY=VALUE lines from config.env (the shell-sourceable file every script sources).
    The process environment wins, so launchd/tests can override a single key."""
    values = {}
    path = os.path.join(home, "config.env")
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                m = _ASSIGN.match(line)
                if m:
                    values[m.group(1)] = _parse_value(m.group(2))
    except OSError:
        pass
    for key, val in os.environ.items():
        if key.startswith("OJOGATO_"):
            values[key] = val
    return values


class Config(object):
    def __init__(self, home=None):
        self.home = os.path.abspath(os.path.expanduser(
            home or os.environ.get("OJOGATO_HOME") or "~/.ojogato"))
        v = load_config(self.home)
        self.bin = os.path.join(self.home, "bin")
        self.frames = os.path.join(self.home, "frames")
        self.bind = (v.get("OJOGATO_MCP_BIND") or "127.0.0.1").strip()
        self.port = int(v.get("OJOGATO_MCP_PORT") or "8790")
        self.token = (v.get("OJOGATO_MCP_TOKEN") or "").strip()
        self.public_url = (v.get("OJOGATO_MCP_PUBLIC_URL") or "").strip().rstrip("/")
        self.media_ttl = int(v.get("OJOGATO_MCP_MEDIA_TTL") or "3600")
        self.bind_ip = None  # resolved lazily; see resolve_bind()

    def media_base(self):
        if self.public_url:
            return self.public_url
        host = self.bind_ip
        if host is None:
            try:
                host = resolve_bind(self.bind)
            except ValueError:
                host = "127.0.0.1"
        if ":" in host:
            host = "[%s]" % host
        return "http://%s:%d" % (host, self.port)


def _tailscale_binary():
    for cand in (shutil.which("tailscale"), "/usr/local/bin/tailscale",
                 "/opt/homebrew/bin/tailscale",
                 "/Applications/Tailscale.app/Contents/MacOS/Tailscale"):
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def resolve_bind(bind):
    """127.0.0.1 | tailscale | an explicit IP. Never a wildcard address."""
    b = (bind or "").strip()
    if b.lower() == "localhost":
        b = "127.0.0.1"
    if b.lower() == "tailscale":
        ts = _tailscale_binary()
        if not ts:
            raise ValueError("OJOGATO_MCP_BIND=tailscale but the tailscale CLI was not found")
        try:
            out = subprocess.run([ts, "ip", "-4"], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 timeout=10, universal_newlines=True)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise ValueError("tailscale ip -4 failed: %s" % e)
        lines = [l.strip() for l in out.stdout.splitlines() if l.strip()]
        if out.returncode != 0 or not lines:
            raise ValueError("tailscale ip -4 returned no address (is Tailscale up?)")
        b = lines[0]
    try:
        ip = ipaddress.ip_address(b)
    except ValueError:
        raise ValueError("OJOGATO_MCP_BIND must be 127.0.0.1, tailscale or an IP address, got %r" % bind)
    if ip.is_unspecified:
        raise ValueError("refusing to bind %s: that listens on every interface. "
                         "Use 127.0.0.1 or tailscale." % b)
    return str(ip)


# --------------------------------------------------------------------------- media signing

def _b64e(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64d(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _sig(token, rel, expiry):
    msg = ("%s\n%d" % (rel, expiry)).encode("utf-8")
    return hmac.new(token.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def _inside(root, path):
    root = os.path.realpath(root)
    real = os.path.realpath(path)
    return real if real.startswith(root + os.sep) else None


def sign_media(cfg, path, now=None):
    """-> (url, expires_at). Only files under $OJOGATO_HOME/frames/ can be signed."""
    if not cfg.token:
        raise ToolError("no OJOGATO_MCP_TOKEN configured, so no media link can be signed "
                        "(run ojogato setup, or use deliver=\"telegram\")")
    real = _inside(cfg.frames, path)
    if not real:
        raise ToolError("refusing to link a file outside %s" % cfg.frames)
    rel = os.path.relpath(real, os.path.realpath(cfg.frames))
    expiry = int(now if now is not None else time.time()) + cfg.media_ttl
    signed = "%s.%d.%s" % (_b64e(rel.encode("utf-8")), expiry, _sig(cfg.token, rel, expiry))
    return "%s/media/%s/%s" % (cfg.media_base(), signed, os.path.basename(real)), expiry


def verify_media(cfg, signed, now=None):
    """-> absolute path of the file, or None. HMAC first, then expiry, then containment."""
    if not cfg.token:
        return None
    parts = signed.split(".")
    if len(parts) != 3:
        return None
    b64, exp_s, sig = parts
    try:
        rel = _b64d(b64).decode("utf-8")
        expiry = int(exp_s)
    except (ValueError, UnicodeDecodeError):
        return None
    if not hmac.compare_digest(_sig(cfg.token, rel, expiry), sig):
        return None
    if expiry < int(now if now is not None else time.time()):
        return None
    if os.path.isabs(rel) or "\x00" in rel:
        return None
    real = _inside(cfg.frames, os.path.join(cfg.frames, rel))
    if not real or not os.path.isfile(real):
        return None
    return real


# --------------------------------------------------------------------------- scripts

class ToolError(Exception):
    """Becomes an MCP tool result with isError: true. Never crashes the server."""


def _script(cfg, name):
    path = os.path.join(cfg.bin, name)
    if not os.path.isfile(path):
        raise ToolError("%s is not installed in %s (update ojogato)" % (name, cfg.bin))
    return path


def _run(cfg, name, args, timeout):
    env = dict(os.environ)
    env["OJOGATO_HOME"] = cfg.home
    try:
        proc = subprocess.run(["/bin/bash", _script(cfg, name)] + list(args),
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=timeout, env=env, cwd=cfg.home)
    except subprocess.TimeoutExpired:
        raise ToolError("%s timed out after %ds" % (name, timeout))
    except OSError as e:
        raise ToolError("%s could not run: %s" % (name, e))
    out = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace")
    return proc.returncode, out, err


def _parse_obj(text):
    text = text.strip()
    if not text:
        return None
    for cand in (text, text.splitlines()[-1]):
        try:
            obj = json.loads(cand)
        except ValueError:
            continue
        if isinstance(obj, dict):
            return obj
    return None


def _fail(name, code, out, err):
    obj = _parse_obj(out)
    if obj and obj.get("error"):
        return ToolError("%s: %s" % (name, obj["error"]))
    tail = (err.strip() or out.strip()).splitlines()[-1:] or ["no output"]
    return ToolError("%s failed (exit %d): %s" % (name, code, tail[0][:300]))


def run_json(cfg, name, args, timeout=SCRIPT_TIMEOUT):
    """One contract JSON object on stdout, exit 0. Anything else is a ToolError."""
    code, out, err = _run(cfg, name, args, timeout)
    if code != 0:
        raise _fail(name, code, out, err)
    obj = _parse_obj(out)
    if obj is None:
        raise ToolError("%s returned no JSON: %s" % (name, (out.strip() or err.strip() or "empty")[:300]))
    if set(obj) == {"error"}:
        raise ToolError("%s: %s" % (name, obj["error"]))
    return obj


def run_ndjson(cfg, name, args, timeout=SCRIPT_TIMEOUT):
    """events.sh --json: one object per line, nothing at all when there are no events."""
    code, out, err = _run(cfg, name, args, timeout)
    if code != 0:
        raise _fail(name, code, out, err)
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            raise ToolError("%s returned a line that is not JSON: %s" % (name, line[:200]))
        if not isinstance(obj, dict):
            raise ToolError("%s returned a non-object line: %s" % (name, line[:200]))
        rows.append(obj)
    return rows


def run_text(cfg, name, args, timeout=SCRIPT_TIMEOUT):
    """The existing Telegram send paths (report.sh, recap.sh): they print a caption."""
    code, out, err = _run(cfg, name, args, timeout)
    if code != 0:
        raise _fail(name, code, out, err)
    return out.strip()


# --------------------------------------------------------------------------- tool helpers

def text_block(obj):
    return {"type": "text", "text": json.dumps(obj, ensure_ascii=False, sort_keys=False)}


def image_block(cfg, path):
    real = _inside(cfg.home, path) if path else None
    if not real or not os.path.isfile(real):
        raise ToolError("image file missing: %s" % path)
    with open(real, "rb") as fh:
        data = fh.read()
    if data[:2] != b"\xff\xd8":
        raise ToolError("image is not a JPEG: %s" % path)
    return {"type": "image", "data": base64.b64encode(data).decode("ascii"), "mimeType": "image/jpeg"}


def _int_arg(args, key, default, lo, hi):
    val = args.get(key, default)
    if val is None:
        return None
    if isinstance(val, bool) or not isinstance(val, (int, float)) or val != int(val):
        raise ToolError("%s must be an integer" % key)
    val = int(val)
    if val < lo or val > hi:
        raise ToolError("%s must be between %d and %d" % (key, lo, hi))
    return val


def _bool_arg(args, key, default):
    val = args.get(key, default)
    if not isinstance(val, bool):
        raise ToolError("%s must be true or false" % key)
    return val


def _deliver_arg(args):
    val = args.get("deliver", "url")
    if val not in ("url", "telegram"):
        raise ToolError('deliver must be "url" or "telegram"')
    return val


def _event_id_arg(args):
    val = args.get("event_id")
    if isinstance(val, int) and not isinstance(val, bool):
        val = str(val)
    if not isinstance(val, str) or not re.match(r"^[0-9]{1,12}$", val):
        raise ToolError("event_id must be the event's start epoch as a string, e.g. \"1760519700\"")
    return val


def _contact_sheet(cfg, video):
    """-> (image block or None, error string or None). A failed sheet never hides the facts."""
    try:
        sheet = run_json(cfg, "contact-sheet.sh", [video, "--frames", "3", "--width", "768"])
        return image_block(cfg, sheet.get("path")), None
    except ToolError as e:
        return None, str(e)


def _attach_url(cfg, facts, path):
    try:
        url, exp = sign_media(cfg, path)
        facts["url"], facts["url_expires_at"] = url, exp
    except ToolError as e:
        facts["url"], facts["url_expires_at"] = None, None
        facts["url_error"] = str(e)


def _with_image(facts, image, sheet_error=None):
    if sheet_error:
        facts["image_error"] = sheet_error
    if image:
        facts["image_note"] = IMAGE_NOTE
        return [text_block(facts), image]
    return [text_block(facts)]


# --------------------------------------------------------------------------- tools

def tool_camera_status(cfg, args):
    st = run_json(cfg, "status.sh", ["--json"])
    st["source"] = "pipeline"
    return [text_block(st)]


def tool_list_events(cfg, args):
    hours = _int_arg(args, "hours", 6, 1, 168)
    real_only = _bool_arg(args, "real_only", True)
    since = _int_arg(args, "since_epoch", None, 0, 10 ** 11)
    now = int(time.time())
    if since is not None and since < now:
        # The frame window has to reach back to since_epoch or older events can't be found.
        hours = min(168, max(hours, int(math.ceil((now - since) / 3600.0))))
    argv = ["--json", "--hours", str(hours)]
    if real_only:
        argv.append("--real-only")
    if since is not None:
        argv += ["--since", str(since)]
    events = run_ndjson(cfg, "events.sh", argv)
    for ev in events:
        if "event_id" not in ev and "start" in ev:
            ev["event_id"] = str(ev["start"])
    return [text_block({"source": "pipeline", "hours": hours, "real_only": real_only,
                        "since_epoch": since, "count": len(events), "events": events})]


def tool_get_snapshot(cfg, args):
    width = _int_arg(args, "max_width", 768, 64, 1920)
    snap = run_json(cfg, "snapshot.sh", ["--max-width", str(width)])
    image = image_block(cfg, snap.get("path"))
    snap["source"] = "camera (live frame)"
    return _with_image(snap, image)


def tool_get_event_frame(cfg, args):
    event_id = _event_id_arg(args)
    ev = run_json(cfg, "events.sh", ["--event", event_id, "--json"])
    ev.setdefault("event_id", event_id)
    facts = {"source": "pipeline", "event": ev}
    bf = ev.get("best_frame") or ""
    if not bf:
        facts["image"] = None
        facts["note"] = ("no frame: the recogniser found no subject in this event (verdict %s)"
                         % ev.get("verdict"))
        return [text_block(facts)]
    path = bf if os.path.isabs(bf) else os.path.join(cfg.home, "motionframes", bf)
    if not os.path.isfile(path) and not os.path.splitext(path)[1]:
        path += ".jpg"
    facts["frame"] = "the event's most confident Vision frame"
    return _with_image(facts, image_block(cfg, path))


def tool_get_last_clip(cfg, args):
    deliver = _deliver_arg(args)
    clip = run_json(cfg, "clip.sh", ["--json"])
    facts = {"source": "pipeline", "deliver": deliver, "clip": clip}
    if not clip.get("path"):
        facts["note"] = "no verified movement to show"
        return [text_block(facts)]
    image, sheet_err = _contact_sheet(cfg, clip["path"])
    if deliver == "url":
        _attach_url(cfg, facts, clip["path"])
    else:
        facts["telegram"] = run_text(cfg, "report.sh", ["now"], timeout=SEND_TIMEOUT)
        facts["delivered"] = "telegram"
    return _with_image(facts, image, sheet_err)


def tool_get_recap(cfg, args):
    deliver = _deliver_arg(args)
    hours = _int_arg(args, "hours", None, 1, 72)
    mx = _int_arg(args, "max", None, 1, 20)
    argv = []
    if hours is not None:
        argv += ["--hours", str(hours)]
    if mx is not None:
        argv += ["--max", str(mx)]
    if deliver == "telegram":
        # recap.sh's own send path builds and sends in one run; building it twice to also
        # return a contact sheet would double a slow ffmpeg job, so this returns the caption.
        caption = run_text(cfg, "recap.sh", argv, timeout=RECAP_TIMEOUT)
        return [text_block({"source": "pipeline", "deliver": deliver,
                            "delivered": "telegram", "telegram": caption})]
    recap = run_json(cfg, "recap.sh", ["--no-send", "--json"] + argv, timeout=RECAP_TIMEOUT)
    facts = {"source": "pipeline", "deliver": deliver, "recap": recap}
    if not recap.get("path"):
        facts["note"] = "nothing to recap in this window"
        return [text_block(facts)]
    image, sheet_err = _contact_sheet(cfg, recap["path"])
    _attach_url(cfg, facts, recap["path"])
    return _with_image(facts, image, sheet_err)


_RO = {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False}
_DELIVER = {"type": "string", "enum": ["url", "telegram"], "default": "url",
            "description": "url: return a signed tailnet link for the human to tap. "
                           "telegram: ojogato's own bot sends the video to the configured chat."}

TOOLS = [
    {
        "name": "camera_status",
        "title": "Camera status",
        "description": "Current state of the Ojo de Gato camera: minutes since a subject was last "
                       "seen (null = nothing seen), verified sightings in 6h/12h (null when vision "
                       "is not on), vision on/stale/off, whether the room is dark, paused, detector "
                       "health and the live view URL. " + HONESTY,
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": dict(_RO, title="Camera status"),
        "handler": tool_camera_status,
    },
    {
        "name": "list_events",
        "title": "List motion events",
        "description": "Motion events from the pipeline, oldest first: start/end epoch, verdict "
                       "(pet/person, or none = noise), Vision score, frame counts and event_id. "
                       "Use since_epoch to ask \"anything new since X?\": only events ending after "
                       "it are returned. An empty list means nothing new. " + HONESTY,
        "inputSchema": {
            "type": "object",
            "properties": {
                "hours": {"type": "integer", "minimum": 1, "maximum": 168, "default": 6,
                          "description": "Look back this many hours (widened to reach since_epoch)."},
                "real_only": {"type": "boolean", "default": True,
                              "description": "Only events where Vision recognised a pet or person."},
                "since_epoch": {"type": "integer", "minimum": 0,
                                "description": "Only events that ended after this unix time."},
            },
            "additionalProperties": False,
        },
        "annotations": dict(_RO, title="List motion events"),
        "handler": tool_list_events,
    },
    {
        "name": "get_snapshot",
        "title": "Live snapshot",
        "description": "One live frame from the camera as a JPEG image, plus JSON with taken_at, "
                       "luma and dark. The image is for you to look at; " + HONESTY,
        "inputSchema": {
            "type": "object",
            "properties": {"max_width": {"type": "integer", "minimum": 64, "maximum": 1920,
                                         "default": 768, "description": "Downscale to this width."}},
            "additionalProperties": False,
        },
        "annotations": dict(_RO, idempotentHint=False, title="Live snapshot"),
        "handler": tool_get_snapshot,
    },
    {
        "name": "get_event_frame",
        "title": "Event frame",
        "description": "The frame Apple Vision was most confident in for one event, as a JPEG "
                       "image, plus the event's verdict and score. event_id comes from "
                       "list_events. " + HONESTY,
        "inputSchema": {
            "type": "object",
            "properties": {"event_id": {"type": "string", "pattern": "^[0-9]+$",
                                        "description": "The event's start epoch, as list_events returns it."}},
            "required": ["event_id"],
            "additionalProperties": False,
        },
        "annotations": dict(_RO, title="Event frame"),
        "handler": tool_get_event_frame,
    },
    {
        "name": "get_last_clip",
        "title": "Last movement clip",
        "description": "Cuts the clip of the last verified movement. Returns JSON (event time, "
                       "verdict, duration, and a signed url when deliver=url) and a 3-frame "
                       "contact-sheet image of the clip. You can't watch the video: relay the url "
                       "to the human, or use deliver=telegram to have ojogato send it. " + HONESTY,
        "inputSchema": {"type": "object", "properties": {"deliver": _DELIVER},
                        "additionalProperties": False},
        "annotations": dict(_RO, idempotentHint=False, title="Last movement clip"),
        "handler": tool_get_last_clip,
    },
    {
        "name": "get_recap",
        "title": "Day recap",
        "description": "Builds the recap video of the day's verified moments (or the last N hours). "
                       "deliver=url returns JSON (moments with times and verdicts, a signed url) "
                       "and a contact-sheet image; deliver=telegram has ojogato send the video and "
                       "returns its caption. Can take up to 3 minutes. " + HONESTY,
        "inputSchema": {
            "type": "object",
            "properties": {
                "hours": {"type": "integer", "minimum": 1, "maximum": 72,
                          "description": "Last N hours instead of today since midnight."},
                "max": {"type": "integer", "minimum": 1, "maximum": 20,
                        "description": "Most moments in the video (default from config, 8)."},
                "deliver": _DELIVER,
            },
            "additionalProperties": False,
        },
        "annotations": dict(_RO, idempotentHint=False, title="Day recap"),
        "handler": tool_get_recap,
    },
]
TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


def call_tool(cfg, name, args):
    tool = TOOLS_BY_NAME[name]
    try:
        return {"content": tool["handler"](cfg, args), "isError": False}
    except ToolError as e:
        return {"content": [{"type": "text", "text": "Error: %s" % e}], "isError": True}
    except Exception as e:  # a bug in a handler must not take the server down
        log("tool %s crashed: %r" % (name, e))
        return {"content": [{"type": "text", "text": "Error: internal error in %s: %s" % (name, e)}],
                "isError": True}


# --------------------------------------------------------------------------- JSON-RPC

class RpcError(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code, self.message = code, message


def _negotiate(params):
    asked = params.get("protocolVersion") if isinstance(params, dict) else None
    return asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]


def handle_request(cfg, method, params):
    if method == "initialize":
        return {
            "protocolVersion": _negotiate(params),
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "title": "Ojo de Gato", "version": SERVER_VERSION},
            "instructions": "Read-only access to an Ojo de Gato pet camera. " + HONESTY,
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{k: v for k, v in t.items() if k != "handler"} for t in TOOLS]}
    if method == "tools/call":
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            raise RpcError(-32602, "tools/call needs a tool name")
        name = params["name"]
        if name not in TOOLS_BY_NAME:
            raise RpcError(-32602, "unknown tool: %s" % name)
        args = params.get("arguments") or {}
        if not isinstance(args, dict):
            raise RpcError(-32602, "arguments must be an object")
        return call_tool(cfg, name, args)
    raise RpcError(-32601, "method not found: %s" % method)


def handle_message(cfg, msg):
    """One JSON-RPC message -> a response dict, or None for notifications and responses."""
    if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
        return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "invalid request"}}
    method = msg.get("method")
    if method is None:
        return None  # a response to something we never asked; ignore
    if "id" not in msg:
        return None  # notification (notifications/initialized, notifications/cancelled, ...)
    rid = msg["id"]
    try:
        if not isinstance(method, str):
            raise RpcError(-32600, "invalid request")
        return {"jsonrpc": "2.0", "id": rid, "result": handle_request(cfg, method, msg.get("params"))}
    except RpcError as e:
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": e.code, "message": e.message}}
    except Exception as e:
        log("request %s crashed: %r" % (method, e))
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "internal error"}}


def handle_payload(cfg, payload):
    """A single message or a batch array -> (response or None)."""
    if isinstance(payload, list):
        if not payload:
            return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "empty batch"}}
        out = [r for r in (handle_message(cfg, m) for m in payload) if r is not None]
        return out or None
    return handle_message(cfg, payload)


# --------------------------------------------------------------------------- stdio

def serve_stdio(cfg):
    log("stdio, OJOGATO_HOME=%s" % cfg.home)
    out = sys.stdout
    for raw in sys.stdin.buffer:
        line = raw.decode("utf-8", "replace").strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except ValueError:
            resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}
        else:
            resp = handle_payload(cfg, payload)
        if resp is not None:
            out.write(json.dumps(resp, ensure_ascii=False) + "\n")
            out.flush()


# --------------------------------------------------------------------------- HTTP

_CTYPES = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".mp4": "video/mp4", ".png": "image/png"}


class Handler(BaseHTTPRequestHandler):
    server_version = "ojogato-mcp/" + SERVER_VERSION
    protocol_version = "HTTP/1.1"

    @property
    def cfg(self):
        return self.server.cfg

    def log_message(self, fmt, *args):
        # The request line of a media fetch carries its signature; never log it.
        line = (fmt % args)
        line = re.sub(r"/media/\S+", "/media/<signed>", line)
        log("%s %s" % (self.address_string(), line))

    def _send(self, code, body=b"", ctype="application/json", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
            ctype = "text/plain; charset=utf-8" if ctype == "application/json" else ctype
        self.send_response(code)
        if body:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _authorized(self):
        auth = self.headers.get("Authorization") or ""
        if not auth.startswith("Bearer "):
            return False
        return hmac.compare_digest(auth[7:].strip().encode("utf-8"), self.cfg.token.encode("utf-8"))

    def _origin_ok(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True
        host = (urlsplit(origin).hostname or "").lower()
        allowed = {"127.0.0.1", "localhost", "::1", (self.server.bind_ip or "").lower()}
        if self.cfg.public_url:
            allowed.add((urlsplit(self.cfg.public_url).hostname or "").lower())
        return host in allowed

    def _gate(self):
        """Origin + bearer checks shared by POST/DELETE /mcp. True when the request may go on."""
        if not self._origin_ok():
            self._send(403, {"error": "origin not allowed"})
            return False
        if not self._authorized():
            self._send(401, {"error": "missing or wrong bearer token"},
                       headers={"WWW-Authenticate": 'Bearer realm="ojogato"'})
            return False
        return True

    def _path(self):
        return urlsplit(self.path).path

    def do_POST(self):
        if self._path() != "/mcp":
            return self._send(404, {"error": "not found"})
        if not self._gate():
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = -1
        if length <= 0 or length > MAX_BODY:
            return self._send(400, {"jsonrpc": "2.0", "id": None,
                                    "error": {"code": -32600, "message": "bad Content-Length"}})
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return self._send(400, {"jsonrpc": "2.0", "id": None,
                                    "error": {"code": -32700, "message": "parse error"}})
        msgs = payload if isinstance(payload, list) else [payload]
        is_init = any(isinstance(m, dict) and m.get("method") == "initialize" for m in msgs)
        headers = {}
        sid = self.headers.get("Mcp-Session-Id")
        if is_init:
            headers["Mcp-Session-Id"] = self.server.new_session()
        elif sid is not None and not self.server.has_session(sid):
            # Spec: an unknown/expired session gets 404 so the client re-initializes.
            return self._send(404, {"jsonrpc": "2.0", "id": None,
                                    "error": {"code": -32001, "message": "unknown session"}})
        resp = handle_payload(self.cfg, payload)
        if resp is None:
            return self._send(202, headers=headers)
        self._send(200, resp, headers=headers)

    def do_DELETE(self):
        if self._path() != "/mcp":
            return self._send(404, {"error": "not found"})
        if not self._gate():
            return
        sid = self.headers.get("Mcp-Session-Id")
        if sid and self.server.drop_session(sid):
            return self._send(200, {})
        self._send(404, {"error": "unknown session"})

    def do_GET(self):
        path = self._path()
        if path == "/mcp":
            return self._send(405, {"error": "this server does not offer an SSE stream"},
                              headers={"Allow": "POST, DELETE"})
        if path.startswith("/media/"):
            return self._media(path[len("/media/"):])
        self._send(404, {"error": "not found"})

    do_HEAD = do_GET

    def _media(self, rest):
        signed = rest.split("/", 1)[0]  # anything after the signature is a cosmetic filename
        real = verify_media(self.cfg, signed)
        if not real:
            return self._send(403, "forbidden\n")
        size = os.path.getsize(real)
        ctype = _CTYPES.get(os.path.splitext(real)[1].lower(), "application/octet-stream")
        start, end, code = 0, size - 1, 200
        rng = self.headers.get("Range")
        m = re.match(r"^bytes=(\d*)-(\d*)$", rng.strip()) if rng else None
        if m and (m.group(1) or m.group(2)) and size > 0:
            # Single byte ranges: iOS Safari won't play an mp4 without them.
            if m.group(1):
                start = int(m.group(1))
                end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
            else:
                start = max(0, size - int(m.group(2)))
            if start > end or start >= size:
                return self._send(416, headers={"Content-Range": "bytes */%d" % size})
            code = 206
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "private, no-store")
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(real, "rb") as fh:
            fh.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = fh.read(min(65536, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)


class McpHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, cfg, bind_ip):
        self.cfg, self.bind_ip = cfg, bind_ip
        self._sessions, self._lock = {}, threading.Lock()
        family_v6 = ":" in bind_ip
        if family_v6:
            import socket
            self.address_family = socket.AF_INET6
        ThreadingHTTPServer.__init__(self, (bind_ip, cfg.port), Handler)

    def new_session(self):
        sid = secrets.token_hex(16)
        with self._lock:
            if len(self._sessions) >= MAX_SESSIONS:
                oldest = min(self._sessions, key=self._sessions.get)
                del self._sessions[oldest]
            self._sessions[sid] = time.time()
        return sid

    def has_session(self, sid):
        with self._lock:
            return sid in self._sessions

    def drop_session(self, sid):
        with self._lock:
            return self._sessions.pop(sid, None) is not None


def serve_http(cfg):
    if not cfg.token:
        raise SystemExit("ojogato-mcp: refusing to start HTTP without OJOGATO_MCP_TOKEN "
                         "(run ojogato setup, or ojogato mcp token)")
    try:
        cfg.bind_ip = resolve_bind(cfg.bind)
    except ValueError as e:
        raise SystemExit("ojogato-mcp: %s" % e)
    httpd = McpHTTPServer(cfg, cfg.bind_ip)
    cfg.port = httpd.server_address[1]  # honours OJOGATO_MCP_PORT=0 (tests)
    log("http on %s:%d (POST /mcp, GET /media/<signed>), OJOGATO_HOME=%s, media base %s"
        % (cfg.bind_ip, cfg.port, cfg.home, cfg.media_base()))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Ojo de Gato MCP server (read-only).")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--stdio", action="store_true", help="newline-delimited JSON-RPC (default)")
    mode.add_argument("--http", action="store_true", help="Streamable HTTP on OJOGATO_MCP_BIND:PORT")
    ap.add_argument("--home", help="OJOGATO_HOME (default $OJOGATO_HOME or ~/.ojogato)")
    opts = ap.parse_args(argv)
    cfg = Config(opts.home)
    if opts.http:
        serve_http(cfg)
    else:
        serve_stdio(cfg)


if __name__ == "__main__":
    main()

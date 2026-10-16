#!/usr/bin/env python3
"""Smoke test for src/mcp/ojogato_mcp.py against the fixture OJOGATO_HOME.

Spawns the server over stdio and over HTTP (127.0.0.1, a free port) with the interpreter
running this file, so `uv run --python 3.9 python tests/mcp/smoke.py` really tests 3.9.
Exercises initialize -> tools/list -> every tool in the happy, empty and error fixture
modes, then the HTTP-only guarantees: bearer token, sessions, refusal to bind 0.0.0.0 or to
start without a token, and signed media (ok / range / expired / tampered / traversal).
Stdlib only. Exit 0 = every check passed.
"""

import base64
import importlib.util
import json
import os
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SERVER = os.path.join(REPO, "src", "mcp", "ojogato_mcp.py")
FIXTURE = os.path.join(REPO, "tests", "fixture", "home")
TOKEN = "fixture-token-" + "0" * 32  # not a real secret; fixtures never hold one
TOOL_NAMES = ["camera_status", "list_events", "get_snapshot", "get_event_frame",
              "get_last_clip", "get_recap"]
STATUS_KEYS = {"generated_at", "paused", "vision", "last_seen_min", "sightings_6h",
               "sightings_12h", "raw_frames_6h", "raw_frames_12h", "detector_alive", "luma",
               "dark", "live_url", "subject", "pet_names"}

spec = importlib.util.spec_from_file_location("ojogato_mcp", SERVER)
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)

PASSED = [0]
WORK = tempfile.mkdtemp(prefix="ojogato-smoke-")
FX_LOG = os.path.join(WORK, "sends.log")


def check(cond, what):
    if not cond:
        raise AssertionError(what)
    PASSED[0] += 1


def env_for(mode, **extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith("OJOGATO_")}
    env.update({"OJOGATO_HOME": FIXTURE, "OJOGATO_FIXTURE_MODE": mode,
                "OJOGATO_FIXTURE_LOG": FX_LOG, "OJOGATO_MCP_TOKEN": TOKEN})
    env.update(extra)
    return env


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def read_log():
    try:
        with open(FX_LOG) as fh:
            return fh.read()
    except OSError:
        return ""


# --------------------------------------------------------------------------- clients

class StdioClient(object):
    label = "stdio"

    def __init__(self, env):
        self.proc = subprocess.Popen([sys.executable, SERVER, "--stdio"], env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(os.path.join(WORK, "stdio.err"), "ab"))
        self.next_id = 0

    def send_raw(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def recv(self, timeout=30):
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if not ready:
            raise AssertionError("stdio: no response within %ss" % timeout)
        line = self.proc.stdout.readline()
        if not line:
            raise AssertionError("stdio: server closed stdout")
        return json.loads(line.decode("utf-8"))

    def rpc(self, method, params=None):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.send_raw(msg)
        resp = self.recv(200)
        check(resp.get("id") == self.next_id, "stdio: response id matches")
        return resp

    def notify(self, method):
        self.send_raw({"jsonrpc": "2.0", "method": method})

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(10)


class HttpClient(object):
    label = "http"

    def __init__(self, env):
        self.port = free_port()
        env = dict(env, OJOGATO_MCP_PORT=str(self.port), OJOGATO_MCP_BIND="127.0.0.1")
        self.proc = subprocess.Popen([sys.executable, SERVER, "--http"], env=env,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=open(os.path.join(WORK, "http.err"), "ab"))
        self.base = "http://127.0.0.1:%d" % self.port
        self.session = None
        self.next_id = 0
        deadline = time.time() + 15
        while True:
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.5).close()
                break
            except OSError:
                if self.proc.poll() is not None or time.time() > deadline:
                    raise AssertionError("http server did not start")
                time.sleep(0.1)

    def post(self, body, token=TOKEN, session="auto", origin=None):
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(self.base + "/mcp", data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        if token is not None:
            req.add_header("Authorization", "Bearer " + token)
        sid = self.session if session == "auto" else session
        if sid:
            req.add_header("Mcp-Session-Id", sid)
        if origin:
            req.add_header("Origin", origin)
        return fetch(req)

    def rpc(self, method, params=None):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        code, headers, body = self.post(msg)
        check(code == 200, "http %s -> 200 (got %s)" % (method, code))
        check(headers.get("Content-Type", "").startswith("application/json"), "http json content-type")
        if method == "initialize":
            self.session = headers.get("Mcp-Session-Id")
            check(bool(self.session), "http initialize issues Mcp-Session-Id")
        resp = json.loads(body.decode("utf-8"))
        check(resp.get("id") == self.next_id, "http: response id matches")
        return resp

    def notify(self, method):
        code, _, body = self.post({"jsonrpc": "2.0", "method": method})
        check(code == 202 and body == b"", "http notification -> 202, empty body (got %s)" % code)

    def close(self):
        self.proc.terminate()
        self.proc.wait(10)


def fetch(req):
    try:
        with urllib.request.urlopen(req, timeout=200) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def get(url, headers=None):
    req = urllib.request.Request(url)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    return fetch(req)


# --------------------------------------------------------------------------- helpers

def call(c, name, **args):
    resp = c.rpc("tools/call", {"name": name, "arguments": args})
    check("result" in resp, "%s %s: result, not a JSON-RPC error (%s)" % (c.label, name, resp.get("error")))
    return resp["result"]


def facts(result):
    check(result["content"][0]["type"] == "text", "first block is text")
    return json.loads(result["content"][0]["text"])


def images(result):
    out = []
    for block in result["content"]:
        if block["type"] == "image":
            check(block["mimeType"] == "image/jpeg", "image mimeType is image/jpeg")
            raw = base64.b64decode(block["data"])
            check(raw[:2] == b"\xff\xd8", "image block decodes to a JPEG (\\xff\\xd8)")
            out.append(raw)
    return out


def ok(result, what):
    check(result.get("isError") is False, "%s: isError false (%s)" % (what, result["content"][0].get("text")))


def err(result, needle, what):
    check(result.get("isError") is True, "%s: isError true" % what)
    text = result["content"][0]["text"]
    check(needle in text, "%s: error mentions %r (got %r)" % (what, needle, text))


def handshake(c):
    resp = c.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "smoke", "version": "0"}})
    res = resp["result"]
    check(res["protocolVersion"] == "2025-06-18", "%s: protocolVersion echoed" % c.label)
    check(res["serverInfo"]["name"] == "ojogato", "serverInfo.name")
    check("tools" in res["capabilities"], "tools capability")
    c.notify("notifications/initialized")
    check(c.rpc("ping")["result"] == {}, "%s: ping" % c.label)

    tools = c.rpc("tools/list")["result"]["tools"]
    check(sorted(t["name"] for t in tools) == sorted(TOOL_NAMES), "%s: exactly the six tools" % c.label)
    for t in tools:
        check(t["annotations"]["readOnlyHint"] is True, "%s readOnlyHint" % t["name"])
        check("own observation" in t["description"], "%s description carries the honesty rule" % t["name"])
        check(t["inputSchema"]["type"] == "object", "%s inputSchema" % t["name"])
    props = {t["name"]: t["inputSchema"].get("properties", {}) for t in tools}
    check(set(props["list_events"]) == {"hours", "real_only", "since_epoch"}, "list_events args")
    check(set(props["get_snapshot"]) == {"max_width"}, "get_snapshot args")
    check(set(props["get_event_frame"]) == {"event_id"}, "get_event_frame args")
    check(set(props["get_last_clip"]) == {"deliver"}, "get_last_clip args")
    check(set(props["get_recap"]) == {"hours", "max", "deliver"}, "get_recap args")

    e = c.rpc("tools/call", {"name": "set_config", "arguments": {}})
    check(e.get("error", {}).get("code") == -32602, "%s: unknown tool -> -32602" % c.label)
    e = c.rpc("no/such/method")
    check(e.get("error", {}).get("code") == -32601, "%s: unknown method -> -32601" % c.label)
    old = c.rpc("initialize", {"protocolVersion": "1999-01-01", "capabilities": {},
                               "clientInfo": {"name": "smoke", "version": "0"}})
    check(old["result"]["protocolVersion"] == mcp.PROTOCOL_VERSIONS[0],
          "%s: unsupported protocolVersion -> server's newest" % c.label)


# --------------------------------------------------------------------------- per-mode checks

def happy(c, expect_url_fetch):
    st = facts(call(c, "camera_status"))
    check(STATUS_KEYS <= set(st), "camera_status carries every contract key")
    check(st["last_seen_min"] == 12 and st["vision"] == "on", "camera_status values")

    r = call(c, "list_events")
    ok(r, "list_events")
    ev = facts(r)
    check(ev["count"] == 2 and len(ev["events"]) == 2, "list_events real_only default -> 2")
    check(all(e["verdict"] in ("pet", "person") for e in ev["events"]), "real_only verdicts")
    check(all(isinstance(e["event_id"], str) for e in ev["events"]), "event_id is a string")
    allev = facts(call(c, "list_events", hours=12, real_only=False))
    check(allev["count"] == 3, "list_events real_only=false -> 3")
    newest = ev["events"][-1]
    since = facts(call(c, "list_events", since_epoch=newest["start"] - 1))
    check([e["event_id"] for e in since["events"]] == [newest["event_id"]], "since_epoch keeps newer only")
    later = facts(call(c, "list_events", since_epoch=newest["end"]))
    check(later["count"] == 0, "since_epoch at the newest end -> empty")
    err(call(c, "list_events", hours="six"), "integer", "list_events bad hours")

    r = call(c, "get_snapshot", max_width=512)
    ok(r, "get_snapshot")
    check(len(images(r)) == 1, "get_snapshot returns one image")
    snap = facts(r)
    check(snap["dark"] is False and "taken_at" in snap and "image_note" in snap, "snapshot facts")

    r = call(c, "get_event_frame", event_id=ev["events"][0]["event_id"])
    ok(r, "get_event_frame")
    check(len(images(r)) == 1, "get_event_frame returns one image")
    check(facts(r)["event"]["verdict"] == "pet", "get_event_frame verdict")
    none_ev = [e for e in allev["events"] if e["verdict"] == "none"][0]
    r = call(c, "get_event_frame", event_id=none_ev["event_id"])
    ok(r, "get_event_frame on a noise event")
    check(images(r) == [] and facts(r)["image"] is None, "noise event: no image, says so")
    err(call(c, "get_event_frame", event_id="12345"), "no such event", "get_event_frame unknown id")
    err(call(c, "get_event_frame", event_id="../../etc"), "event_id", "get_event_frame bad id")

    open(FX_LOG, "w").close()
    r = call(c, "get_last_clip")
    ok(r, "get_last_clip url")
    check(len(images(r)) == 1, "get_last_clip contact sheet image")
    lc = facts(r)
    check(lc["clip"]["verdict"] == "person" and lc["url"] and lc["url_expires_at"] > time.time(),
          "get_last_clip facts + signed url")
    check(lc["url"].startswith("http://127.0.0.1:"), "url derived from bind+port")
    if expect_url_fetch:
        code, h, body = get(lc["url"])
        check(code == 200 and h.get("Content-Type") == "video/mp4", "clip url fetch ok")
        with open(os.path.join(FIXTURE, "frames", "lastmove.mp4"), "rb") as fh:
            check(body == fh.read(), "clip url serves the clip bytes")
    check(read_log() == "", "deliver=url sends nothing")
    r = call(c, "get_last_clip", deliver="telegram")
    ok(r, "get_last_clip telegram")
    check(facts(r)["delivered"] == "telegram", "get_last_clip telegram delivered")
    check("report.sh now" in read_log(), "deliver=telegram shells out to report.sh now")
    err(call(c, "get_last_clip", deliver="carrier-pigeon"), "deliver", "bad deliver")

    open(FX_LOG, "w").close()
    r = call(c, "get_recap", hours=6, max=4)
    ok(r, "get_recap url")
    check(len(images(r)) == 1, "get_recap contact sheet image")
    rc = facts(r)
    check(len(rc["recap"]["moments"]) == 2 and rc["url"], "get_recap moments + url")
    if expect_url_fetch:
        code, h, body = get(rc["url"], {"Range": "bytes=0-9"})
        check(code == 206 and len(body) == 10 and h.get("Content-Range", "").startswith("bytes 0-9/"),
              "recap url honours Range (206)")
    r = call(c, "get_recap", deliver="telegram", hours=3)
    ok(r, "get_recap telegram")
    check("recap.sh --hours 3" in read_log(), "deliver=telegram shells out to recap.sh (send path)")


def empty(c):
    st = facts(call(c, "camera_status"))
    check(st["last_seen_min"] is None and st["sightings_6h"] == 0, "empty status: null last_seen")
    ev = facts(call(c, "list_events", since_epoch=int(time.time()) - 3600))
    check(ev["count"] == 0 and ev["events"] == [], "empty list_events -> []")
    r = call(c, "get_snapshot")
    ok(r, "empty-mode snapshot")
    check(facts(r)["dark"] is True and len(images(r)) == 1, "dark snapshot still an image")
    r = call(c, "get_last_clip")
    ok(r, "empty get_last_clip")
    check(facts(r)["clip"]["path"] is None and images(r) == [], "no clip: path null, no image")
    r = call(c, "get_recap")
    ok(r, "empty get_recap")
    check(facts(r)["recap"]["moments"] == [] and images(r) == [], "no recap: moments [], no image")


def error(c):
    err(call(c, "camera_status"), "status failed", "status error")
    err(call(c, "list_events"), "events failed", "events error")
    err(call(c, "get_snapshot"), "stream down", "snapshot stream down")
    err(call(c, "get_event_frame", event_id="1760519700"), "events failed", "event frame error")
    err(call(c, "get_last_clip"), "clip failed", "clip error")
    err(call(c, "get_recap"), "recap failed", "recap error")
    check(c.rpc("ping")["result"] == {}, "%s: server alive after script errors" % c.label)


# --------------------------------------------------------------------------- HTTP-only

def http_security(c):
    init = {"jsonrpc": "2.0", "id": 99, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "smoke", "version": "0"}}}
    code, h, _ = c.post(init, token=None, session=None)
    check(code == 401 and "Bearer" in h.get("WWW-Authenticate", ""), "no token -> 401")
    code, _, _ = c.post(init, token="wrong", session=None)
    check(code == 401, "wrong token -> 401")
    code, _, _ = c.post({"jsonrpc": "2.0", "id": 1, "method": "ping"}, session="not-a-session")
    check(code == 404, "unknown Mcp-Session-Id -> 404")
    code, _, _ = c.post({"jsonrpc": "2.0", "id": 1, "method": "ping"}, origin="http://evil.example")
    check(code == 403, "foreign Origin -> 403")
    code, _, body = c.post([{"jsonrpc": "2.0", "id": 7, "method": "ping"},
                            {"jsonrpc": "2.0", "method": "notifications/initialized"}])
    check(code == 200 and [r["id"] for r in json.loads(body)] == [7], "batch -> array of responses")
    code, _, _ = get(c.base + "/mcp")
    check(code == 405, "GET /mcp -> 405 (no SSE)")

    cfg = mcp.Config(FIXTURE)
    cfg.token, cfg.port, cfg.bind_ip, cfg.public_url = TOKEN, c.port, "127.0.0.1", ""
    snap = os.path.join(FIXTURE, "frames", "snapshot.jpg")
    url, _ = mcp.sign_media(cfg, snap)
    code, h, body = get(url)
    check(code == 200 and h.get("Content-Type") == "image/jpeg" and body[:2] == b"\xff\xd8",
          "signed media fetch ok")
    expired, _ = mcp.sign_media(cfg, snap, now=time.time() - cfg.media_ttl - 60)
    check(get(expired)[0] == 403, "expired media url -> 403")
    signed = url.split("/media/")[1].split("/")[0]
    b64, exp, sig = signed.split(".")
    bad = "%s/media/%s.%s.%s" % (c.base, b64, exp, ("0" if sig[0] != "0" else "1") + sig[1:])
    check(get(bad)[0] == 403, "tampered signature -> 403")
    later = "%s/media/%s.%d.%s" % (c.base, b64, int(exp) + 99999, sig)
    check(get(later)[0] == 403, "extended expiry without re-signing -> 403")
    for rel in ("../config.env", "../vision/verdicts.tsv", "../../../../../../etc/hosts",
                "/etc/hosts"):
        e = int(time.time()) + 600
        forged = "%s.%d.%s" % (mcp._b64e(rel.encode()), e, mcp._sig(TOKEN, rel, e))
        check(get("%s/media/%s/x" % (c.base, forged))[0] == 403, "traversal %r -> 403" % rel)
    raw = urllib.request.Request(c.base + "/media/..%2fconfig.env")
    check(fetch(raw)[0] == 403, "unsigned traversal -> 403")
    try:
        mcp.sign_media(cfg, os.path.join(FIXTURE, "config.env"))
        check(False, "sign_media refuses files outside frames/")
    except mcp.ToolError:
        check(True, "sign_media refuses files outside frames/")
    code, _, _ = c.post({"jsonrpc": "2.0", "id": 1, "method": "ping"})
    check(code == 200, "session still valid")


def refusals():
    for bind in ("0.0.0.0", "::", "nonsense"):
        p = subprocess.run([sys.executable, SERVER, "--http"], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
                           env=env_for("happy", OJOGATO_MCP_BIND=bind, OJOGATO_MCP_PORT=str(free_port())))
        check(p.returncode != 0, "refuses to start on bind %r" % bind)
        if bind != "nonsense":
            check(b"refusing" in p.stderr, "bind %r refusal says why" % bind)
    p = subprocess.run([sys.executable, SERVER, "--http"], stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
                       env=env_for("happy", OJOGATO_MCP_TOKEN="", OJOGATO_MCP_PORT=str(free_port())))
    check(p.returncode != 0 and b"OJOGATO_MCP_TOKEN" in p.stderr, "refuses HTTP with an empty token")
    for bind in ("0.0.0.0", "::", "0", ""):
        try:
            mcp.resolve_bind(bind)
            check(False, "resolve_bind rejects %r" % bind)
        except ValueError:
            check(True, "resolve_bind rejects %r" % bind)
    check(mcp.resolve_bind("127.0.0.1") == "127.0.0.1", "resolve_bind 127.0.0.1")
    check(mcp.resolve_bind("localhost") == "127.0.0.1", "resolve_bind localhost")


def stdio_without_token():
    c = StdioClient(env_for("happy", OJOGATO_MCP_TOKEN=""))
    try:
        handshake(c)
        r = call(c, "get_last_clip")
        ok(r, "stdio clip without a token")
        lc = facts(r)
        check(lc["url"] is None and "OJOGATO_MCP_TOKEN" in lc["url_error"], "no token: url null + why")
    finally:
        c.close()


def main():
    print("smoke: python %s, server %s" % (sys.version.split()[0], SERVER))
    try:
        for Client in (StdioClient, HttpClient):
            for mode, fn in (("happy", None), ("empty", empty), ("error", error)):
                c = Client(env_for(mode))
                try:
                    handshake(c)
                    if mode == "happy":
                        happy(c, expect_url_fetch=(Client is HttpClient))
                        if Client is HttpClient:
                            http_security(c)
                    else:
                        fn(c)
                finally:
                    c.close()
                print("  ok  %-5s %s" % (Client.label, mode))
        stdio_without_token()
        print("  ok  stdio without token")
        refusals()
        print("  ok  refusals (0.0.0.0, ::, empty token)")
    except AssertionError as e:
        print("FAIL: %s" % e)
        for name in ("stdio.err", "http.err"):
            p = os.path.join(WORK, name)
            if os.path.exists(p):
                print("--- %s (tail)" % name)
                print("".join(open(p).readlines()[-15:]))
        return 1
    finally:
        shutil.rmtree(WORK, ignore_errors=True)
    print("smoke: PASS (%d checks)" % PASSED[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())

# Roadmap

v1 is macOS-only, single-camera, deterministic-only. These are the directions for v2, roughly in priority order. The design constraint stays fixed throughout: **the deterministic core never depends on an LLM** — new intelligence is always an optional layer on top of a pipeline that works without it.

## MCP server (shipped in v0.4.0)

Any MCP-capable agent can query the camera: status and verified events as JSON, the snapshot and an event's best frame as images the agent can look at, and clips/recaps as tailnet links or the video itself. Design: [mcp-server.md](mcp-server.md).

## Linux / VPS support

The pipeline is already 90% portable: mediamtx, ffmpeg, and shell. The macOS-specific parts are three: the `avfoundation` camera input, launchd, and subject recognition (Apple's Vision framework, which would need an on-device replacement such as a small local detector model). The port is:

- **RTSP input instead of avfoundation.** On Linux the capture source becomes any RTSP camera (or a v4l2 device). Everything downstream — mediamtx, the fragmented-mp4 recorder, the mpdecimate motion detector, report/clip/heartbeat — consumes RTSP already and moves unchanged.
- **systemd units instead of launchd plists.** Same six services, same labels, rendered as unit files.

The interesting deployment this unlocks: **agent-on-VPS with a camera-node-at-home**. A cheap always-on VPS runs the agent and report logic; a small box at home (or the Mac) publishes the camera over the tailnet as an RTSP node. Tailscale makes the two machines feel adjacent, footage still never touches the public internet, and the home machine no longer has to be awake for the agent to be.

## Optional LLM-vision garnish

Today the agent narrates numbers and never claims to see images. The vision layer would let it *actually* look: pass the live snapshot (or last-movement frames) to a vision model and return an accurate scene description — "both cats on the couch, one asleep" — clearly sourced from a model, not fabricated.

- **Provider-agnostic:** a thin adapter over whichever vision API you configure; no lock-in, works with local models too.
- **Cost-honest:** a described snapshot is one small image per request — around pennies per day even with digests.
- **Still garnish:** motion stats, clips, alarms, and the watchdog remain fully deterministic. If the vision call fails or is unconfigured, reports fall back to exactly what v1 sends. Descriptions are labeled as model output so the honesty rule survives the upgrade.

## Multi-camera

Multiple mediamtx paths (`/cam1`, `/cam2`, …), one recorder + motion detector pair per path, per-camera config blocks, and reports that aggregate ("movement in the kitchen 3 min ago, living room quiet for 2h"). The heartbeat gains per-camera freshness checks.

## Masking zones

Ignore regions of the frame that generate honest-but-useless motion: a window onto street traffic, a TV, a ceiling fan. Implemented deterministically as a crop/drawbox mask in the motion detector's filter chain — per-camera rectangles in config, no models involved. This is the main answer to environments where threshold tuning alone can't get the static baseline to zero.

## Generalized subjects

`OJOGATO_SUBJECT` already makes the messages say what you're watching. Generalizing further means subject profiles that tune the whole pipeline, not just the wording:

- **Pets** — the v1 default: daytime no-motion alarm, activity digests.
- **Plants / passive spaces** — motion is the *anomaly*; alert on unexpected movement instead of on quiet.
- **Doors / packages** — zone-focused motion (composes with masking zones), immediate clip on trigger rather than twice-daily digests.
- **Elder check-in** — the no-motion alarm as the primary feature: configurable quiet-hours windows, escalation to a second contact, and deliberately conservative wording. Highest-stakes use of the same deterministic signal, so it ships last and most carefully.

## Smaller items

- `ojogato doctor` growth: TCC grant verification, tailnet reachability probe, motion-baseline self-test (automating the [validation protocol](motion-tuning.md)).
- Retention policies per data type (keep motion-adjacent segments longer than idle ones).
- A simple local timeline page (over the tailnet only) for scrubbing the last 48h of recordings.

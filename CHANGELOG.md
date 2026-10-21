# Changelog

All notable changes to Ojo de Gato are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [0.4.0] — 2026-10-20

Any MCP-capable agent can now use Ojo de Gato, not only OpenClaw, and digests no longer
need an agent at all.

### Added
- **MCP server** (`src/mcp/ojogato_mcp.py`): stdlib Python 3.9+, stdio for a local agent and
  Streamable HTTP for a remote one (for example an agent on a VPS reaching the camera Mac over
  Tailscale). Six read-only tools: `camera_status`, `list_events`, `get_snapshot`,
  `get_event_frame`, `get_last_clip`, `get_recap`. Facts come back as JSON from the pipeline.
  The snapshot and the frame Apple Vision was most confident about come back as images the
  agent can look at. Clips and recaps come back as signed links on your tailnet, or go straight
  to Telegram. Bearer token required, it refuses to bind `0.0.0.0`, and no tool can turn the
  camera off. Off by default (`OJOGATO_MCP_ENABLED=1`, `ojogato mcp status|token|url`). See
  [docs/mcp-server.md](docs/mcp-server.md), including the cron-poll recipe for having an
  agent check for new sightings on a schedule.
- **Standalone digests** (`com.ojogato.digest`): 09:00 report and 21:00 recap without an
  agent. `OJOGATO_DIGEST_MODE=standalone|agent|off`; install picks `agent` when OpenClaw is
  present so digests are never sent twice.
- Machine-readable pipeline output for agents: `status.sh --json`, `snapshot.sh`,
  `contact-sheet.sh`, `events.sh --json` with `event_id`, `--event ID` and `--since EPOCH`,
  `clip.sh --json`, `recap.sh --no-send --json`. Default (human) output of every existing
  script is unchanged.
- **The lid is the switch** (`com.ojogato.lid`): on a MacBook, closing the lid pauses
  everything and opening it resumes. A manual `ojogato off` stays off until `ojogato on`.
  `OJOGATO_LID_SWITCH=0` turns it off.
- **Media into the agent's own chat:** `get_snapshot` and `get_event_frame` also return a
  signed link, and `get_last_clip` / `get_recap` take `deliver="inline"` to return the mp4
  itself as an embedded resource. Hermes attaches both to its replies out of the box.
- **Hermes example skill** (`examples/hermes/ojogato-cats/`): answers about the pets with the
  photo and videos attached, and runs 9am/9pm digests that go silent while the camera is
  paused and say once when the camera Mac can't be reached.
- Test suites: `tests/hooks/run.sh` (pipeline contract + golden default outputs) and
  `tests/mcp/smoke.py` (protocol, tools, auth, media signing), both runnable without a camera.

### Fixed
- `recap` failed every moment cut on ffmpeg builds without the `drawtext` filter (current
  Homebrew among them) and wrongly said the footage had rolled off. Moments now go out
  unlabelled instead.
- With the lid closed, capture kept running against no camera, writing hundreds of MB of
  errors while the watchdog reported a dead stream. The lid switch pauses it instead.
- `OJOGATO_MCP_BIND=tailscale` failed under launchd, where the Tailscale app binary prints a
  GUI error and exits 0. Only a real tailnet address is accepted now, with the network
  interfaces as the fallback.
- The watchdog could crash reading the recogniser's liveness file mid-write. The file is now
  written atomically.

## [0.3.0] — 2026-09-24

### Added
- **`ojogato recap`** (`recap.sh`) — the day's key moments as one short video, sent to
  Telegram. Only vision-verified events (pet or person) qualify; they are ranked by how many
  frames showed the subject, picked with a 15-minute spacing rule so the reel covers the day,
  then played in chronological order. Each 8s moment is centred on the event's most
  confident frame (detector-lag corrected, same anchor as the last-movement clip) and carries
  a time label. `--hours N` for a window other than today, `--max N` (default 8),
  `--no-send` to build without sending. Checks Telegram's reply instead of assuming delivery.
  Tunables: `OJOGATO_RECAP_MAX`, `OJOGATO_RECAP_MOMENT_SECS`, `OJOGATO_RECAP_SPREAD_MIN`.
- OpenClaw skill: "send me the recap" / "highlights" runs `ojogato recap`.
- `report.sh digest --recap` — the evening (21:00) digest now sends the day's recap video in
  place of the single last-movement clip; the morning digest is unchanged.

## [0.2.0] — 2026-08-15

Motion reports stop meaning "pixels changed" and start meaning "a subject was there."

Three releases have now tried to make a pixel-difference metric behave like a subject
detector — `deflicker` in 0.1.1, tighter burst clustering in 0.1.1, lag-corrected clip
windows in 0.1.2 — and each narrowed the problem without removing it. Measured on the
reference camera on 2026-08-15: **1,655 motion frames in a day, of which only 24 runs
contained a cat, dog or person.** The 6-hour report read "243 motion moments" over a room
that had been empty since 10:38, and the "last movement" clip sent to the phone was
anchored on an auto-exposure burst at 13:34 and showed an empty corridor. Thirty-six
consecutive "motion" frames between 13:37 and 14:03 were hand-checked: every one an empty
room, the only thing changing being the webcam's own exposure and white balance.

No threshold fixes that, because the signal genuinely is a large pixel change. So the
detector keeps its job — a cheap proposer, 86,400 frames/day down to a few thousand
candidates — and a new layer decides what actually happened.

### Added
- **`ojogato-vision`** — on-device subject recognition built on Apple's Vision framework
  (`VNRecognizeAnimalsRequest` + `VNDetectHumanRectanglesRequest`). No model download, no
  network, no API key, no Python; compiled by `install.sh` with `swiftc`. Nothing about the
  camera leaves the machine.
  - **Tiled inference** (`OJOGATO_VISION_TILES`, default `3x2`) is load-bearing, not an
    optimisation. Vision downsamples its input, so a cat down the corridor yields *no
    observation at all* rather than a low-confidence one — which is why lowering the
    confidence floor recovers nothing and only tiling does. Measured over one day:
    full-frame 199 animal frames, 3x2 tiled 349, same floor, no new false positives.
- **`events.sh`** — the single definition of "motion". An EVENT is a run of candidate
  frames no more than `OJOGATO_EVENT_GAP` (default 30s) apart, and it is REAL only if a
  subject was recognised in **at least one** of its frames.
  - Event-level, not frame-level, is the whole design. The recogniser legitimately misses
    individual frames — a ragdoll with its back turned, pale fur against pale tile, a
    person cropped to a forearm — but a subject that is really in the room stays for
    seconds and lands in many frames, while exposure flicker produces runs where it is
    recognised in none. Validated over 24h: 43 real events, each with a plausible duration
    and a confident best frame; zero false positives in a hand-checked empty window.
- **`com.ojogato.vision`** launchd service (`vision-run.sh`): classifies new frames
  oldest-first into an append-only, idempotent verdict cache, with its own liveness file so
  a dead verifier can never read as a quiet room.
- `ojogato status` separates **`last candidate frame`** from **`last sighting`**, and
  reports verified sightings, noise events and candidate frames side by side.
- Watchdog check for a capture process that is running but has used no CPU — the camera
  wedged rather than the software, previously invisible for 30 minutes.
- `install.sh --rebuild-app` to force an app-bundle rebuild.

### Changed
- `motion-stats.sh` reports `MOTION_EVENTS_LAST_<N>H` (verified sightings) and
  `NOISE_EVENTS_LAST_<N>H`. `MOTION_FRAMES_LAST_<N>H` survives as a diagnostic — the gap
  between it and the event count is the measure of detector noise — but is no longer what a
  human is shown as "activity". `VISION=on|off|stale` says which regime produced the numbers.
- `clip.sh` anchors on the last **verified** event and places the window over the frames
  where the subject was actually seen, centring on the highest-confidence frame when the
  sighting is too long to show whole. Falls back to the old burst anchor, labelled
  `unverified`, when the verifier is off or has seen nothing in
  `OJOGATO_CLIP_LOOKBACK_HOURS`.
- `report.sh` captions clips with what was recognised — "The cats at 14:20", "Someone came
  by at 09:14" — instead of "Last movement", which was a promise the system could not keep.
  An unverified clip says so.
- `events.sh` resolves frame timestamps one calendar day at a time instead of forking
  `date` per frame: ~50s → 0.2s, and `report.sh` calls it three times.
- `cleanup.sh` prunes verdict rows whose frames are past retention.

### Fixed
- **`install.sh` rebuilt `OjoGato.app` on every run, silently risking the camera
  permission.** The up-to-date test compared the *unsigned* `ffmpeg` against the *signed*
  app binary, which can never be equal because `codesign` embeds ~649KB of signature. Every
  `ojogato update` therefore re-signed the bundle that exists solely to hold the TCC camera
  grant — and re-granting needs a human in System Settings, which on a headless watcher
  means the camera is dead until someone walks over to it. The bundle is now stamped with
  hashes of what it was built from; pre-stamp bundles are adopted rather than rebuilt.
- `ojogato on` restarted a hardcoded list of services while `ojogato off` stopped
  `$CAM_SERVICES`; the two drifted the moment a service was added, leaving
  `com.ojogato.vision` stopped after any pause. `on` now derives its list from `off`'s.

## [0.1.3] — 2026-08-10

Fixes a silent 12h45m blackout: the detector reported no movement all morning while a
person walked through the room repeatedly. Not a tuning problem — replaying the exact same
filter chain against recordings of the same minutes kept 62 frames. The ffmpeg process was
alive, its RTSP socket connected and its decoder burning CPU, but its filter graph had
stalled on an input-timestamp discontinuity: RTSP's 32-bit 90 kHz clock wraps about every
13h15m, and to `fps` a wrap looks like time jumping backwards by hours, after which it
drops every frame waiting for a source time that never arrives.

The deeper problem was that nothing could have noticed. A wedged detector and an empty room
produce the identical observable — zero motion frames — so every existing check read
healthy. This release adds a signal that separates them.

### Added
- `frames/detector-alive.jpg`: written unconditionally every `OJOGATO_DETECTOR_ALIVE_SEC`
  (default 30) from a second detector output taken before mpdecimate. A fresh mtime proves
  decode + filter + mux are all still moving, whatever the room is doing.
- Detector watchdog in `heartbeat.sh`: restarts the motion service when that frame goes
  older than `OJOGATO_DETECTOR_STALL_SEC` (default 180) and reports having done it. Rate
  limited to one restart per 15 min so a stream that cannot come up isn't kicked in a loop.
- **Day/night motion profiles**, chosen by measured light rather than by the clock.
  `motion-profile.sh` samples mean luma (reusing the liveness frame, so it costs nothing),
  applies hysteresis between `OJOGATO_DARK_YAVG` and the new `OJOGATO_LIT_YAVG`, writes
  `~/.ojogato/profile.env`, and restarts the detector only when the regime actually changed.
  `OJOGATO_PROFILE_MODE` = `auto` (default) | `schedule` | `day` | `night` | `off`; night
  thresholds via `OJOGATO_NIGHT_MOTION_{HI,LO,FRAC,PREFILTER}` (72/36/0.6).
  `motion-profile.sh --print` shows the decision without applying it.
- `ojogato status` prints a `detector:` liveness line and the active motion profile,
  deliberately separate from `last motion`.

### Changed
- Detector input takes `-use_wallclock_as_timestamps 1`, making the filter graph immune to
  any source-timestamp wrap, reset, or reconnect.
- `com.ojogato.heartbeat` interval 1800s → 300s: it now owns the stall check, and half an
  hour of a blind camera is half an hour of missed cats. A clean pass reads one still frame
  and exits; Telegram alerts stay rate-limited to one per 3h.
- docs/motion-tuning.md: sections on the wedged-detector failure mode and on why the profile
  switch keys on light, with the measured sweep behind both. The load-bearing number: a lit
  room at 21:00 (luma 40) keeps 8 frames of a real person on the day profile and 4 on the
  night one — a clock-driven switch would have halved a true event.

## [0.1.2] — 2026-08-09

Fixes "last movement" clips that showed an empty room even when the detector had
correctly caught a real subject. This was not a false positive: v0.1.1's `deflicker`
prefilter buffers 5 frames before it can emit one, so motion-frame timestamps trail
real wall-clock time by ~6s, while the recordings (a straight `-c copy`) do not. The
clip's 3-second lead-in was smaller than that lag, so every clip opened after the
subject had already left. Verified against footage of a person crossing the frame:
the old window was flat empty, the new one puts them dead centre.

### Added
- `OJOGATO_DETECT_LAG` (default 6): seconds the detector's frame timestamps trail
  wall clock. `clip.sh` subtracts it before cutting.
- `OJOGATO_DARK_YAVG` (default 16): mean-luma line below which the scene counts as
  unlit. With no IR, a dark frame is mostly sensor grain — counts inflate and clips
  show nothing — so reports now say so instead of implying we saw something.
- `frames/lastmove.meta`: the clip's lag-corrected event time and mean luma, written
  by `clip.sh` and read by `report.sh`.
- docs/motion-tuning.md: detector-lag section with a re-measurement recipe, and a
  darkness section recording that denoising does *not* fix dark-frame grain
  (`hqdn3d` at three strengths moved the kept-frame count 7 → 7 → 7).

### Changed
- Clip window widened to 4s lead-in + 6s tail (12–20s total, was 9–15s) so a few
  seconds of lag error still leaves the subject inside the clip.
- `report.sh` captions the clip with the lag-corrected event time from
  `lastmove.meta` rather than the newest motion frame's filename, which named a
  moment several seconds after the subject had already left.

### Fixed
- Clips whose window straddled a 10-minute segment boundary were silently truncated
  to whatever remained of the first segment (a 12s window came back 4s long).
  `clip.sh` now cuts across every overlapping segment via the concat demuxer.

## [0.1.1] — 2026-08-09

Fixes the second phantom-motion class: auto-exposure steps. The detector was firing
in storms that tracked daylight (559 frames in one hour, empty room) because the
webcam's exposure re-metering shifts global luma, spiking per-block SAD at every
high-contrast edge — enough to clear even very high `hi` thresholds. Reports and
"last movement" clips anchored on those storms and showed an empty room.

### Added
- `OJOGATO_MOTION_PREFILTER` (default `deflicker=size=5:mode=am`): normalizes global
  luma before mpdecimate so only local change survives; `"null"` disables.
- `OJOGATO_BURST_GAP` (default 4s, was hardcoded 10s) and `OJOGATO_BURST_MIN`
  (default 2): burst clustering is now configurable and shared by `clip.sh` and
  `motion-stats.sh`.
- `motion-stats.sh` prints `LAST_FRAME_MIN` (raw newest-frame age) alongside the
  burst-aware `LAST_MOTION_MIN`.
- docs/motion-tuning.md: auto-exposure-step section + offline replay-tuning protocol
  (validate candidate thresholds against your own recordings of known-empty and
  known-motion windows instead of only live baselines).

### Changed
- Motion defaults retuned against real footage: `hi=48 lo=24 frac=0.6`
  (was `28/14/0.4`).
- `motion-stats.sh` `LAST_MOTION_MIN` is burst-aware — an isolated false-positive
  frame no longer refreshes "last activity".
- `clip.sh` burst gap tightened 10s → 4s: two isolated exposure blips 5–10s apart
  could previously pair into a fake "burst" and clip an empty room.

## [0.1.0] — 2026-08-08

Initial release. macOS-only, single camera.

### Added
- Camera → mediamtx pipeline: hardware-encoded capture (avfoundation + h264_videotoolbox), RTSP loopback-only transport, HLS/WebRTC live view over the tailnet.
- Rolling recorder: 10-minute fragmented-mp4 segments (`-c copy`), retention by age and size cap.
- Continuous motion detection via ffmpeg `mpdecimate` with tunable per-block thresholds and area fraction; timestamped motion frames as the ground truth for all activity stats.
- `report.sh`: on-demand and digest reports to Telegram — live snapshot, honest activity stats, live-view URL, and an ~9s clip of the last real movement (`clip.sh`).
- Watchdog `heartbeat.sh` outside the agent: stream/recording/disk checks, daytime no-motion alarm, rate-limited direct Telegram alerts, respects the `PAUSED` flag.
- TCC solution for headless camera capture: ad-hoc-signed `OjoGato.app` bundle (`com.ojogato.capture`) with a one-time guided permission grant.
- `install.sh` + `ojogato` CLI (`setup|on|off|status|doctor|report|clip|logs|update|uninstall`), template-rendered launchd services, single `~/.ojogato/config.env` config.
- OpenClaw integration (`openclaw/register.sh` / `unregister.sh`): skill install, AGENTS.md section, exec allowlist, optional digest crons — idempotent, with timestamped backups.
- Docs: TCC deep-dive, motion tuning + validation protocol, privacy and networking (Tailscale-first), OpenClaw integration, roadmap.

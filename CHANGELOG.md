# Changelog

All notable changes to Ojo de Gato are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

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

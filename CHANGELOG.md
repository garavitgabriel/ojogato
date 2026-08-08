# Changelog

All notable changes to Ojo Gato are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

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

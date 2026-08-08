# Privacy and networking

Ojo Gato is a camera pointed at the inside of your home. The networking design starts from that fact.

## The stance

- **No cloud. No accounts. No third-party video service.** There is nothing to sign up for and no server of ours involved. The pipeline runs entirely on your Mac.
- **Footage never leaves your machines.** Recordings and motion frames live in `~/.ojogato/` and are deleted on a rolling window (48h / 9 GB by default). The live stream is only reachable from devices you own, over your tailnet.
- **Tailscale-first.** Remote viewing rides your existing [Tailscale](https://tailscale.com) network — an encrypted WireGuard mesh between your own devices. No accounts beyond the ones you already have, no ports opened to the internet.

The one deliberate egress is **Telegram**: snapshots, clips, and alerts you asked for are sent to your chat via the Telegram Bot API over HTTPS. If that trade-off doesn't suit you, don't configure the Telegram token — the live view and local recordings work without it.

## How the ports are laid out

| Service | Bind | Reachable from |
|---|---|---|
| RTSP (internal transport) | `127.0.0.1:8554` | This Mac only |
| HLS (live view) | `:8888` | Your tailnet |
| WebRTC (live view) | `:8889` | Your tailnet |

**RTSP is loopback-only, by design.** It is the raw internal bus — the recorder, motion detector, and snapshot tool all read from `rtsp://127.0.0.1:8554/cam`. It is never exposed off the machine, and there is no configuration option to expose it.

**HLS and WebRTC bind all interfaces**, which in practice means: your LAN and your Tailscale address. The live URL that setup configures (`OJOGATO_LIVE_URL`) uses your Tailscale MagicDNS name, e.g. `http://your-mac.your-tailnet.ts.net:8889/cam`. From your phone, turn Tailscale on and the URL works from anywhere; without Tailscale, it doesn't resolve. That's the access control model: membership in your tailnet.

## Never port-forward

Do not forward ports 8888/8889 (or any Ojo Gato port) on your router, and do not put them behind a public reverse proxy. The streams carry live video of your home with no authentication layer of their own — the security model is *network reachability*, and it only holds if reachability stays private. Tailscale gives you remote access without ever opening a port; there is no scenario where port-forwarding is the right tool here.

If you want to harden further:

- Use Tailscale ACLs to restrict which of your devices can reach ports 8888/8889 on the camera Mac.
- Keep the Mac's macOS firewall on; the launchd services need no inbound rules beyond mediamtx.
- `ojogato off` pauses the entire stack (creates `~/.ojogato/PAUSED`) when you want the camera verifiably idle — the heartbeat respects it too.

## What data exists, and where

| Data | Location | Lifetime |
|---|---|---|
| Rolling recordings (10-min mp4 segments) | `~/.ojogato/recordings/` | 48h, capped at 9 GB (configurable) |
| Motion frames (timestamped JPEGs) | `~/.ojogato/motionframes/` | Rolling cleanup |
| Snapshots / clips built for reports | `~/.ojogato/frames/` | Hours |
| Config incl. Telegram token | `~/.ojogato/config.env` (chmod 600) | Until you delete it |
| Snapshots/clips you requested | Your Telegram chat | Telegram's retention, under your account |

Nothing is uploaded anywhere else, ever. `ojogato uninstall` removes the services and the `~/.ojogato/` directory.

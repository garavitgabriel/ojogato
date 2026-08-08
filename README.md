# Ojo de Gato

**Give your OpenClaw agent eyes.** A private, self-hosted camera monitor for the space (and pets) you care about.

Ojo de Gato ("cat eye" in Spanish) turns a Mac with a camera into a monitoring station you talk to over Telegram — directly, or through your OpenClaw agent.

## What you get

- **Ask and see.** Text your agent "how are the cats?" and get back a live snapshot, honest activity stats ("last activity 4 min ago, 23 motion moments in the last 6h"), a live-view URL, and a short clip of the last real movement.
- **Twice-daily digests.** A 9am and 9pm summary of activity, delivered without asking.
- **A watchdog that watches the watcher.** A heartbeat runs outside the agent and the pipeline. If the stream dies, recording stalls, disk runs low, or the room goes too quiet during the day, it texts you directly — rate-limited so a broken stack doesn't spam you.
- **Live view from your phone.** WebRTC/HLS stream reachable over your Tailscale network only.
- **Rolling recordings.** 10-minute segments with automatic retention (48h / 9 GB cap by default), so "what happened around 3pm?" is answerable.

## Design philosophy: deterministic core, LLM garnish

Everything that matters is plain ffmpeg and shell — it cannot hallucinate:

- Motion detection is continuous frame differencing (ffmpeg `mpdecimate`), not a model guessing.
- Activity stats are counts of saved motion frames and file timestamps. They are either right or verifiably wrong.
- The "last movement" evidence is a real ~9 second clip cut from the recording around the actual motion event — never a "best guess" still.
- The watchdog is launchd plus `curl`. It fires whether or not any agent is alive.

The LLM only adds voice. When OpenClaw is connected, the agent runs the same deterministic report script and relays its output conversationally — it never invents what it "sees". If you skip OpenClaw entirely, the same reports arrive as plain Telegram messages. The LLM is optional garnish; the pipeline is the meal.

## Quickstart

```sh
git clone https://github.com/garavitgabriel/ojogato.git
cd ojogato
./install.sh
ojogato setup
```

`install.sh` fetches ffmpeg and mediamtx for your architecture, builds and signs the camera app bundle, and installs the launchd services. `ojogato setup` walks you through the one-time camera permission click, the Telegram bot wizard, and Tailscale URL detection.

Then message your bot — or, with OpenClaw, run `openclaw/register.sh` and just ask your agent.

## Requirements

- A Mac with a camera (built-in or USB). macOS-only in v1.
- A Telegram account (the setup wizard creates the bot connection).
- [Tailscale](https://tailscale.com) recommended, for the live view from your phone.
- OpenClaw **optional** — standalone Telegram mode works without it.

## Architecture

```
  camera (avfoundation)
          |
   capture-stream.sh          ffmpeg, hardware h264, ~0.22 GB/h
          |
          v
       mediamtx  ------ RTSP, loopback-only 127.0.0.1:8554
      /    |    \
     v     v     v
  live   recorder   motion detector
  view   record.sh  motion-run.sh
  WebRTC 10-min     continuous ffmpeg
  :8889  fragmented mpdecimate ->
  HLS    mp4        timestamped
  :8888  segments   motion frames
 (tailnet   |           |
   only)    +-----+-----+
                  |
                  v
         report.sh / clip.sh     snapshot + stats + ~9s clip
                  |
                  v
              Telegram

  heartbeat.sh — deliberately OUTSIDE everything above.
  Plain launchd + curl; alerts you when the stack breaks
  or the room goes too quiet.
```

Recordings use **fragmented mp4**, which is what lets `clip.sh` cut a clip out of the segment that is still being written — no waiting for the file to close.

## Honest limitations

- **No night vision** on built-in Mac cameras. Leave a light on, or use a USB camera with IR.
- **The lid must stay open** to use a MacBook's built-in camera. Closing the lid kills the feed.
- **macOS-only in v1.** Linux/VPS support is on the [roadmap](docs/roadmap.md).
- Motion detection sees pixel change, not meaning. It counts "something moved", not "a cat moved" — see [motion tuning](docs/motion-tuning.md) for keeping that count honest.

## Docs

- [Why headless camera access fails on macOS (and the fix)](docs/tcc-camera-permission.md) — the TCC deep-dive.
- [Motion tuning](docs/motion-tuning.md) — the phantom-motion story, the two knobs, and the validation protocol.
- [Privacy and networking](docs/privacy-and-networking.md) — Tailscale-first, no cloud, no accounts.
- [OpenClaw integration](docs/openclaw-integration.md) — what `register.sh` sets up and what the agent experience feels like.
- [Roadmap](docs/roadmap.md) — Linux/VPS, optional LLM vision, multi-camera, and more.

## License

[MIT](LICENSE) — Gabriel Garavit.

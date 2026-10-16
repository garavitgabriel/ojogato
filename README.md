# Ojo de Gato

**Your Mac already knows what a cat looks like.** Ojo de Gato turns a Mac with a camera into a private pet monitor. It uses the image recognition built into macOS to check every bit of motion, and it only reports a moment once it has actually seen a cat, a dog or a person. Ask your AI agent how the cats are, and it answers from what the Mac actually saw.

Ojo de Gato means "cat's eye" in Spanish.

<!-- demo: docs/media/demo.gif — Telegram: "how are the cats?" → snapshot + sightings → "send me the recap" → time-labelled recap video -->

## The problem it solves

Basic motion detection on a webcam is close to useless. The camera keeps adjusting its own exposure and white balance, and every adjustment looks like movement. On the reference camera, over one day:

> **1,655 "motion" frames. Only 24 visits that actually had a cat, dog or person in them.**

Before recognition was added, the report said "243 motion moments in the last 6h" about a room that had been empty since morning, and the "last movement" clip sent to my phone showed an empty corridor.

Changing the thresholds can't fix that, because the camera really is changing a lot of pixels. What fixes it is having something look at the frames.

## On-device recognition: the part that matters

Motion detection only suggests that something might have happened. **Apple's Vision framework, running on your Mac, decides whether it did.**

- **Everything stays on the Mac.** `VNRecognizeAnimalsRequest` and `VNDetectHumanRectanglesRequest` ship with macOS. There's no model to download, no network call, no API key and no account. A camera pointed at your living room doesn't need the internet to tell a cat from a lighting change.
- **It answers one closed question:** cat, dog, person or nothing, with a confidence score you can check. It never describes a scene and never makes things up.
- **It decides per visit, not per frame.** A cat with its back turned, or pale fur on a pale floor, gets missed in individual frames. But a cat that's really in the room shows up across many frames, and recognising it in just one of them is enough. Exposure flicker never gets recognised in any of them. Over a full day of validation that meant 24 real events and zero false positives in a window checked by hand as empty.
- **It still sees subjects far away.** Vision shrinks its input, so a cat at the end of a hallway would otherwise go unnoticed. The frame is split into overlapping tiles so distant subjects still get detected. On the reference camera that raised detected animal frames from 199 to 349 a day, with no new false positives.
- **It tells you when it's off.** You can turn recognition off (`OJOGATO_VISION_ENABLED=0`), and if it stops working the reports say so. They label the counts as unverified instead of passing camera noise off as cats.

Every count, every "last seen" time, every clip and every recap is built from these verified events, so they can't disagree with each other.

## What you get

- **Ask and see.** Ask "how are the cats?" and you get a live snapshot, activity stats ("last seen 4 min ago, 6 sightings in 6h"), a link to the live view, and a ~9-second clip of the last time something was actually recognised.
- **A daily recap video.** `ojogato recap` picks the day's best moments (up to 8, spread across the day), puts a time label on each, and joins them into one short video. It only uses moments where a subject was recognised. The 9pm digest sends it automatically.
- **Twice-daily digests** at 9am and 9pm, scheduled by your agent.
- **A watchdog that runs separately from everything else.** It's plain launchd plus `curl`, outside the agent and the pipeline. If the stream dies, recording stalls, the disk runs low, the detector freezes, or the room is too quiet during the day, it messages you directly. It limits how often it messages, so a broken setup doesn't spam you.
- **Live view from your phone** over WebRTC or HLS, reachable only on your Tailscale network.
- **Rolling recordings** in 10-minute segments, kept for 48 hours or up to 9 GB by default, so you can answer "what happened around 3pm?".
- **Light-aware detection.** Day and night settings switch based on how bright the room actually is, not the clock. In the dark, reports say "lights are off" instead of counting sensor noise.

## Works with your agent, or without one

The monitoring doesn't depend on any AI model. Agents only change how you talk to it.

- **Standalone:** watchdog alerts reach you on Telegram with no agent at all, and `ojogato report` / `ojogato recap` send a report or recap from the command line. Asking questions in chat needs an agent.
- **[OpenClaw](https://openclaw.ai):** run `openclaw/register.sh` and just ask your agent. It runs the same report scripts and relays what they found in its own voice. → [OpenClaw integration](docs/openclaw-integration.md)
- **Any MCP-capable agent:** *in progress.* An MCP server (the standard way AI agents connect to tools) so Hermes, Claude Code, Codex and others can query the camera, including an agent on a server reaching a camera at home over Tailscale.

The rule for every agent is the same: **the agent words the answer, but the facts come from the recognition pipeline.** It never claims to see something the recognition didn't confirm.

## Quickstart

```sh
git clone https://github.com/garavitgabriel/ojogato.git
cd ojogato
./install.sh
ojogato setup
```

`install.sh` downloads ffmpeg and mediamtx for your architecture, builds and signs the camera app bundle and the on-device recognition helper (`ojogato-vision`), and installs the launchd services. `ojogato setup` walks you through allowing camera access once, connecting your Telegram bot, and detecting your Tailscale URL.

Then run `ojogato report` to get your first snapshot on Telegram. With OpenClaw, run `openclaw/register.sh` and ask your agent.

## Requirements

- A Mac with a camera (built-in or USB). macOS only for now, because recognition runs on Apple's Vision framework.
- A Telegram account. The setup wizard connects the bot.
- [Tailscale](https://tailscale.com), recommended for the live view from your phone.
- An agent is optional.

## Architecture

```
  camera (avfoundation, resolved by name)
          |
   capture-stream.sh          ffmpeg, hardware h264, ~0.22 GB/h
          |
          v
       mediamtx  ------ RTSP, loopback-only 127.0.0.1:8554
      /    |    \
     v     v     v
  live   recorder   motion detector
  view   record.sh  motion-run.sh
  WebRTC 10-min     ffmpeg deflicker + mpdecimate
  :8889  fragmented   -> CANDIDATE frames
  HLS    mp4           ("pixels changed")
  :8888  segments          |
 (tailnet   |              v
   only)    |    vision-run.sh / ojogato-vision
            |    Apple Vision, on-device, tiled
            |    cat / dog / person / nothing?
            |              |
            |              v
            |         events.sh   candidates -> EVENTS
            |                     real iff a subject was
            |              |      seen in >= 1 frame
            +------+-------+
                   |
                   v
     report.sh / clip.sh / recap.sh
     snapshot + sightings + clip + day recap
                   |
                   v
       Telegram  (directly, or via your agent)

  heartbeat.sh: deliberately OUTSIDE everything above.
  Plain launchd + curl. It alerts you when the stack breaks
  or the room goes too quiet.
```

Recordings use **fragmented mp4**, which lets `clip.sh` and `recap.sh` cut footage from the segment that's still being written, without waiting for the file to close.

## Design philosophy: reliable core, AI optional

Everything that matters is plain ffmpeg, shell and Apple's on-device classifier, and none of it can make things up:

- Motion detection is continuous frame differencing. It's cheap, and it's allowed to be wrong.
- Recognition is a classifier with a confidence score, not a narrator.
- Activity stats count verified events, and the frames behind them stay on disk. You can always go back and check.
- The "last movement" evidence is a real clip cut from the recording around the recognised event. It's never a guessed still image.
- The watchdog fires whether or not any agent is running.

The LLM only adds voice, and it's optional.

## Honest limitations

- **No night vision** on built-in Mac cameras. Leave a light on, or use a USB camera with IR.
- **The lid must stay open** to use a MacBook's built-in camera. Closing it cuts the feed.
- **macOS only for now.** Linux support (an RTSP camera with systemd) is on the [roadmap](docs/roadmap.md).
- **Recognition is good, not perfect.** Something that crosses the frame in under a second, in the dark, can be missed entirely.
- **Cat vs dog isn't reliable** at this resolution, so both are reported as one "pet" class named from `OJOGATO_SUBJECT`. Recognition can't tell individual animals apart either, so pet names (`OJOGATO_PET_NAMES`) refer to the group, never to one pet.

## Docs

- [Motion tuning](docs/motion-tuning.md): the phantom-motion story, the settings you can adjust, and how to validate them.
- [Why headless camera access fails on macOS (and the fix)](docs/tcc-camera-permission.md): a deep dive on macOS camera permissions (TCC).
- [Privacy and networking](docs/privacy-and-networking.md): Tailscale first, no cloud, no accounts.
- [OpenClaw integration](docs/openclaw-integration.md): what `register.sh` sets up and what using it with the agent is like.
- [Roadmap](docs/roadmap.md): MCP server, Linux/VPS, multiple cameras, masking zones.
- [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE) — Gabriel Garavit.

# Motion tuning

Ojo de Gato's activity stats are only as honest as the motion detector. This page covers how detection works, how it goes wrong (the phantom-motion story), which knobs fix it, and how to prove your settings are right.

## How detection works

One ffmpeg process runs continuously against the local RTSP stream:

```
-vf "fps=${OJOGATO_MOTION_FPS},${OJOGATO_MOTION_PREFILTER},mpdecimate=hi=64*${OJOGATO_MOTION_HI}:lo=64*${OJOGATO_MOTION_LO}:frac=${OJOGATO_MOTION_FRAC}" -fps_mode vfr
```

The stream is sampled down to `OJOGATO_MOTION_FPS` (default 1 fps), and `mpdecimate` drops every frame that is "similar enough" to the previous one. Whatever survives is, by definition, a frame where something changed — it gets written to `~/.ojogato/motionframes/` with a timestamp filename. All stats (`last activity N min ago`, `motion moments last 6h`) are just counts and mtimes of those files.

### Why continuous, not sampled

An earlier design sampled the camera in bursts — a few seconds of analysis every minute. That detector is **blind ~90% of the time**: a 6s-look-per-60s sampler misses any movement in the other 54 seconds, which for a cat walking through a room is most movements. Continuous decimation watches every second at 1 fps for near-zero CPU (the frames are already decoded once for the pipeline), so "no motion recorded" actually means no motion happened — not "we weren't looking".

## The phantom-motion story

The first deployment of this pipeline reported constant activity: **"last activity 0 min ago"** at every check, motion-frame counts **in the thousands** per day — in an empty room. Every stat was technically computed correctly, and every one was a lie about the room.

The cause wasn't cats. It was the **camera itself**: auto-exposure and sensor noise make nearly every pixel of every frame differ *slightly* from the last. With loose thresholds, `mpdecimate` treats that global shimmer as change and saves everything. The detector was measuring the camera, not the room.

### Symptoms of over-sensitivity

- Reports always say "last activity 0 min ago" or similar, at any hour.
- `motionframes/` grows by thousands of files a day.
- Motion counts don't drop at night or when the room is verifiably empty.
- The "last movement" clip shows an empty, static room.

If you see these, don't trust a single stat until you've re-tuned and re-validated.

## The two knobs — and which one actually works

`mpdecimate` compares frames in 8x8 pixel blocks. Three parameters matter:

| Config key | mpdecimate param | Meaning |
|---|---|---|
| `OJOGATO_MOTION_HI` | `hi` (x64) | Per-block difference above which a single block alone marks the frame as changed |
| `OJOGATO_MOTION_LO` | `lo` (x64) | Per-block difference above which a block counts as "changed" for the fraction test |
| `OJOGATO_MOTION_FRAC` | `frac` | Fraction of blocks that must exceed `lo` for the frame to count as changed |

Intuition says fight phantom motion with `frac` — "require more of the image to change". **In practice, raising the per-block `hi`/`lo` thresholds beats raising the area fraction**, because exposure flicker is exactly the failure mode `frac` can't fix: auto-exposure shifts *every* block a little, so any area-based test is satisfied no matter how high you set the fraction. What distinguishes flicker from a real subject is the *magnitude* of per-block change — flicker moves each block slightly, a cat moves the blocks it covers a lot. Raise `hi` and `lo` until small global shifts are ignored, and keep `frac` moderate so a real subject (which changes a limited area, strongly) still registers.

The shipped defaults reflect this tuning:

```
OJOGATO_MOTION_FPS="1"
OJOGATO_MOTION_HI="48"
OJOGATO_MOTION_LO="24"
OJOGATO_MOTION_FRAC="0.6"
OJOGATO_MOTION_PREFILTER="deflicker=size=5:mode=am"
```

Edit them in `~/.ojogato/config.env`, then restart the detector:

```sh
launchctl kickstart -k gui/$(id -u)/com.ojogato.motion
```

## Auto-exposure steps: the second phantom, and deflicker

Raising `hi`/`lo` defeats *shimmer* — the constant slight global noise. There is a second, sneakier phantom that thresholds alone can't fully kill: **auto-exposure steps**. When the webcam re-meters (clouds pass, someone moves elsewhere in the room, daylight ramps), it shifts the whole frame's brightness in one jump. At every high-contrast edge (door frames, floor seams, dark objects on light walls) that jump produces a *large* per-block difference — large enough to clear even very high `hi` values via the single-block trigger. The tell: false frames arrive in storms that track **daylight hours**, not activity, and two consecutive saved frames show an identical room at slightly different brightness.

Two defenses ship enabled:

1. **`deflicker` prefilter** (`OJOGATO_MOTION_PREFILTER`) — normalizes global luma across a rolling window *before* mpdecimate compares frames, so only local change survives. This is why `hi` can stay moderate (protecting sensitivity to a small or low-contrast pet) instead of being cranked until real subjects risk being missed.
2. **Burst clustering** (`OJOGATO_BURST_GAP`, `OJOGATO_BURST_MIN`) — real events produce runs of consecutive-second frames; residual exposure blips land as isolated frames several seconds apart. Both the last-movement clip and the "last activity" stat only count a cluster of ≥ `OJOGATO_BURST_MIN` frames ≤ `OJOGATO_BURST_GAP` seconds apart. An isolated frame is recorded but never anchors evidence. (`LAST_FRAME_MIN` in `motion-stats.sh` output still exposes the raw newest-frame age for debugging the detector itself.)

## Replay tuning: validate against your own recordings

You don't have to tune live. The rolling recordings are the same stream the detector sees, so candidate settings can be replayed offline against footage of *known* content — a window you've verified is empty, and a window with a real crossing:

```sh
FF=~/.ojogato/bin/ffmpeg
# count kept frames for a candidate filter chain over a known window
$FF -nostats -ss <offset> -t <secs> -i ~/.ojogato/recordings/<segment>.mp4 -an \
  -vf "fps=1,deflicker=size=5:mode=am,mpdecimate=hi=64*48:lo=64*24:frac=0.6,showinfo" \
  -fps_mode vfr -f null - 2>&1 | grep -c "pts_time:"
```

The empty window should keep ~1 frame (mpdecimate always keeps the first); the crossing should keep several consecutive ones. Sweep parameters until both hold, then write the winners to `config.env`. This is how the shipped defaults were derived — a live "0 in 30 quiet minutes" check validates only the lighting regime you ran it in; replay lets you test the worst storm your camera ever produced.

## The validation protocol

Never trust tuning by eyeballing stats. Two tests, in order, and the settings pass only if both do:

**1. Static baseline must read zero.**
Point the camera at the room, ensure nothing moves (no pets in the room, no fans, no blowing curtains, no TV in frame), and leave it for 30-60 minutes. Then:

```sh
find ~/.ojogato/motionframes -mmin -30 | wc -l
```

The answer must be **0**. Even a handful of frames per hour in a static room means your daily counts are noise-dominated — raise `OJOGATO_MOTION_HI`/`OJOGATO_MOTION_LO` and repeat.

**2. A real walk must register.**
Walk through the frame at normal speed, once. Within a minute or two the count should tick up and a report should show fresh "last activity". If your walk *doesn't* register, you've overshot — lower the thresholds a step and redo both tests.

Zero on static, positive on a walk: that's the entire contract. When both hold, "23 motion moments in the last 6h" means something.

## Detector lag: why a correct detection still clipped an empty room

Detection and recording are two clocks, and they do not agree.

Motion frames are named by `strftime` at the moment ffmpeg **writes the JPEG**, not the moment the camera saw the subject. `deflicker=size=N` cannot emit a frame until it has N frames to average — at `OJOGATO_MOTION_FPS=1` that alone is ~5 seconds — and RTSP plus decode buffering adds about a second more. The recordings have no such delay: the recorder is a straight `-c copy` of the same stream.

Measured on the reference install: a person crossing at **21:22:44–46** in the recordings produced motion frames stamped **21:22:49–51**. A steady **~6 second** lag.

The original clip window took a 3-second lead-in before the burst — *smaller than the lag* — so every clip opened after the subject had already walked out. The detector was right and the clip was late, but the symptom looked identical to a false positive: the camera claims movement, the video shows an empty room.

`clip.sh` now subtracts `OJOGATO_DETECT_LAG` (default 6) before cutting, and widens the window to 4s of lead-in and 6s of tail so a few seconds of lag error still leaves the subject inside.

**Re-measure the lag whenever you change `OJOGATO_MOTION_FPS` or the prefilter** — the deflicker window is the dominant term, so halving the fps roughly doubles the lag:

```bash
# 1. Pick a motion frame you can actually see a subject in; note its filename timestamp.
# 2. Step through the segment covering that time, one second at a time.
#    Bigger JPEG = more detail in frame = subject present.
ffmpeg -v error -ss <offset> -i recordings/<segment>.mp4 -t 20 -vf fps=1 -q:v 5 /tmp/s-%03d.jpg
ls -l /tmp/s-*.jpg
# 3. lag = (motion-frame timestamp) - (wall-clock time of the frames showing the subject)
```

A related trap the wider window exposed: a clip whose window straddles a segment boundary must be cut across **both** files. Cutting from only the segment holding the window's start silently truncates the clip to whatever little of that file remained. `clip.sh` feeds every overlapping segment through the concat demuxer.

## The failure that looks like nothing at all: a wedged detector

Every failure above is the detector saying too much. This one is the detector saying nothing, and it is harder to catch precisely because silence is also what a quiet room looks like.

On 2026-08-10 the reference install reported no movement all morning while a person walked through the room repeatedly. Nothing was misconfigured. The evidence:

- Last motion frame written **23:51:53** the night before; **zero** in the following 12h45m.
- The ffmpeg process was alive, its RTSP socket ESTABLISHED, its decoder threads accumulating CPU the whole time.
- Replaying the **same** filter chain against the recordings of the **same** minutes kept **62 frames** on the segment covering the person's crossing.

Right settings, live stream, running process, no output. The filter graph had stalled while everything around it kept working.

The mechanism is a timestamp discontinuity. RTSP carries a 32-bit 90 kHz clock, which wraps roughly every **13 hours 15 minutes**. To the `fps` filter a wrap looks like time jumping backwards by hours, and `fps` responds by dropping frames until source time catches up to what it has already emitted — which, after a jump that size, is never. The recorder never noticed, because `-c copy` runs no filter graph.

Two defenses ship enabled, because the class of bug matters more than this instance of it:

1. **`-use_wallclock_as_timestamps 1` on the detector's input.** Frames are stamped when they arrive rather than by whatever the source claims, so no wrap, reset, or reconnect can move the filter graph's clock backwards.
2. **A liveness frame plus a watchdog.** The detector writes `frames/detector-alive.jpg` every `OJOGATO_DETECTOR_ALIVE_SEC` (default 30) from a second output taken *before* mpdecimate, unconditionally. `heartbeat.sh` runs every 5 minutes, restarts the detector when that file goes older than `OJOGATO_DETECTOR_STALL_SEC` (default 180), and says so in the alert. Defense 1 addresses the cause we found; defense 2 covers the ones we haven't.

Why a liveness frame is necessary at all, stated plainly: **"no motion frames" cannot distinguish a wedged detector from an empty room**, so no amount of watching `motionframes/` would have caught this. The unconditional frame is the only signal that separates them. `ojogato status` prints it as a `detector:` line next to `last motion`; they mean different things.

If you ever see a long, suspiciously clean run of zeros:

```sh
ojogato status                      # detector: alive / STALLED
tail ~/.ojogato/logs/profile.log    # profile switches and automatic restarts
```

## Day and night: two profiles, chosen by light rather than by clock

The detector's correct sensitivity depends on how much light the sensor has, and that is not a function of the time of day. `motion-profile.sh` measures mean luma every 5 minutes (reusing the liveness frame, so it costs nothing) and switches the detector between a **day** and a **night** threshold set.

Measured on the reference camera — kept frames over 10-minute segments:

| Window | Mean luma | 48/24 (day) | 72/36 (night) | 96/48 |
|---|---|---|---|---|
| Daylight, person walking through | ~90 | **62** | — | — |
| Daylight, verified empty | ~90 | 1 | — | — |
| Dim, lights just out | 11 | 6 | 3 | 3 |
| Deep night, 02:00–05:00 | ~2 | 1 | 1 | 1 |
| **21:00, lamp on, person present** | **40** | **8** | **4** | **3** |

The last row is the whole argument. At that hour a clock-driven switch would have been in "night" mode and thrown away half the frames of a real person. The room was lit — luma 40 — so a light-driven switch correctly keeps it on the day profile. The converse holds too: a shuttered room at 15:00 is the night regime no matter what the clock says.

Note also that deep darkness produces **no** false frames at any threshold on this camera. The night profile earns its keep only in the dim band around luma 7–15, where gain is high but the sensor hasn't bottomed out — a real gain, and a modest one. It is not a fix for night; nothing is, without IR.

```
OJOGATO_PROFILE_MODE="auto"     # auto (luma) | schedule (clock) | day | night | off
OJOGATO_DARK_YAVG="16"          # below -> night
OJOGATO_LIT_YAVG="24"           # above -> day; between, the current profile holds
OJOGATO_NIGHT_MOTION_HI="72"
OJOGATO_NIGHT_MOTION_LO="36"
OJOGATO_NIGHT_MOTION_FRAC="0.6"
```

The gap between `DARK` and `LIT` is hysteresis, and it is not decoration: a single threshold flaps at dusk, and every flap restarts the detector. The active profile is written to `~/.ojogato/profile.env` (generated — edit `config.env` instead), sourced by `motion-run.sh` after `config.env`, and shown by `ojogato status`. Inspect the decision without changing anything:

```sh
~/.ojogato/bin/motion-profile.sh --print
# mode=auto luma=91.2 (via detector-alive.jpg) dark<16 lit>24 current=day -> day
```

Set `OJOGATO_PROFILE_MODE="off"` to go back to a single profile driven only by `OJOGATO_MOTION_*`.

## Darkness: the regime where the numbers stop meaning anything

There is no IR illumination. Once the lights go out the sensor runs at maximum gain and the frame is essentially black — mean luma around **8/255**, against roughly **43** for the same room lit. At that gain the picture is mostly grain, and grain is exactly what `mpdecimate` is built to notice, so counts drift up while the footage shows nothing a human could identify.

Denoising does not rescue this. Replay-testing `hqdn3d` at several strengths over a known-empty dark window changed the kept-frame count by zero (7 → 7 → 7); only raising thresholds moved it, and that costs real sensitivity to a small dark cat. No tuning makes a black frame informative.

So the system stops pretending instead. `OJOGATO_DARK_YAVG` (default 16, comfortably between 8 and 43) is the line: below it, reports say the lights are off, the counts are unreliable, and the clip shows nothing — rather than presenting a dark-inflated number as if it were cats. **The real fix is a lamp on a timer**, not a filter chain.

## Environment notes

- **Sunlight is motion.** A patch of sun crawling across the floor produces real, honest pixel change over minutes. Expect low, slow counts from it; masking zones are on the [roadmap](roadmap.md).
- **Re-validate after moving the camera**, changing the room's lighting, or swapping cameras — thresholds tuned for one sensor's noise profile don't automatically fit another.
- Reflective surfaces (TVs, mirrors, windows onto a street) put outside motion inside your frame. Angle the camera away, or wait for masking zones.

# Motion tuning

Ojo de Gato's activity stats are only as honest as the motion detector. This page covers how detection works, how it goes wrong (the phantom-motion story), which knobs fix it, and how to prove your settings are right.

## How detection works

One ffmpeg process runs continuously against the local RTSP stream:

```
-vf "fps=${OJOGATO_MOTION_FPS},mpdecimate=hi=64*${OJOGATO_MOTION_HI}:lo=64*${OJOGATO_MOTION_LO}:frac=${OJOGATO_MOTION_FRAC}" -fps_mode vfr
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
OJOGATO_MOTION_HI="28"
OJOGATO_MOTION_LO="14"
OJOGATO_MOTION_FRAC="0.4"
```

Edit them in `~/.ojogato/config.env`, then restart the detector:

```sh
launchctl kickstart -k gui/$(id -u)/com.ojogato.motion
```

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

## Environment notes

- **Sunlight is motion.** A patch of sun crawling across the floor produces real, honest pixel change over minutes. Expect low, slow counts from it; masking zones are on the [roadmap](roadmap.md).
- **Re-validate after moving the camera**, changing the room's lighting, or swapping cameras — thresholds tuned for one sensor's noise profile don't automatically fit another.
- Reflective surfaces (TVs, mirrors, windows onto a street) put outside motion inside your frame. Angle the camera away, or wait for masking zones.

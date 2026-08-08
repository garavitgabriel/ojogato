---
name: ojo-gato
description: Check on whatever the Ojo Gato home camera is watching (OJOGATO_SUBJECT in ~/.ojogato/config.env — cats, a dog, plants, the front door). Use whenever the user asks how the subject is doing, asks to check on them, asks for a camera update, or mentions "ojo gato" or the camera ("how are the cats", "check on the dog", "how are the plants", "camera check", "anything on the camera?", "see the cats"). Reports deterministic motion-based activity and sends a live snapshot plus a last-movement clip to Telegram.
---

# Ojo Gato Skill

This machine runs Ojo Gato, a private, self-hosted camera monitor. What the camera watches
is configured as `OJOGATO_SUBJECT` in `~/.ojogato/config.env` (e.g. "the cats"). You are the
friendly face on top of a deterministic monitoring stack — the stack does the watching, you
do the talking.

## On-demand check ("how are the cats?", "camera check")

Run this with exec and relay its printed output, spoken naturally:

```
$HOME/.ojogato/bin/report.sh now
```

(`scripts/run.sh` in this skill does the same; it defaults to `now`.)

The script **sends all media itself** — a live snapshot and a short clip of the last real
movement go straight to the user's Telegram. You do NOT attach images. Just relay the
activity summary conversationally, e.g. "Just checked — last activity 4 minutes ago,
pretty active this afternoon. Sent you a live shot and the last-movement clip."
If the user asks where to watch live, the URL is in the script's output (it comes from
`OJOGATO_LIVE_URL` and needs Tailscale on the phone).

## Scheduled digest

Run `$HOME/.ojogato/bin/report.sh digest` and return ONLY its exact output.

## Rules

- **Never claim to see the frames.** Activity counts and "last movement" times come from
  deterministic motion detection (ffmpeg mpdecimate), not from you looking at images.
  Report the activity level and last-seen time; never invent what the subject is doing,
  where it is, or that it "looks fine".
- **Paused / down states:** if the script says the camera is paused or the stream is down,
  tell the user plainly — do not soften, guess, or reassure.
- **Controls:** `$HOME/.ojogato/bin/ojogato on|off|status` toggles the camera stack or shows
  service state. Only run these when the user explicitly asks to turn the camera on/off or
  asks whether the services are running.

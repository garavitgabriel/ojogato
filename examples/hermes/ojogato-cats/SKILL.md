---
name: ojogato-cats
description: "Answer questions about the pets at home from the Ojo de Gato camera (MCP server 'ojogato'): status, live photo, last clip, day recap and scheduled digests, with the photo and videos attached in this chat."
version: 0.4.0
author: Ojo de Gato
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Smart-Home, Camera, Pets, MCP]
    homepage: https://github.com/garavitgabriel/ojogato
---

# Ojo de Gato: the pets at home

Use this when the user asks about the pets, the camera or home: "how are the cats?",
"anything new?", "show me the kitchen", "send me the clip", "send me the recap",
"is the camera on?". It also drives the scheduled digests below.

The camera runs on a Mac at home. It is reached through the `ojogato` MCP server, whose
tools are read-only. Apple Vision on that Mac decides whether a pet or person was really
there; you only word the answer.

## Rules

1. **Facts come from the tools, never from you.** Counts, "last seen", sightings and
   verdicts are exactly what the tools return. If `vision` is not `on`, say the counts are
   unverified. Never say a pet is visible unless you can see it in the image yourself.
2. **Start with `camera_status`.** Its `subject` and `pet_names` say how to refer to the
   pets ("the cats", by group: the camera can't tell one pet from another, so never name
   a single pet as the one seen).
3. **If `paused` is true:** the owner switched the camera off. Say so in one line and stop.
4. **If the `ojogato` tools are missing or fail to connect:** the camera Mac is off, asleep or offline. Say that in
   one line. Don't retry in a loop.
5. **Attach media, don't describe links.** Photos and videos go into this chat as files:
   - Image blocks from `get_snapshot` / `get_event_frame` are saved for you and come back
     as a `MEDIA:<path>` line. Put that line, unchanged, on its own line at the end of
     your reply.
   - For video, call `get_last_clip` or `get_recap` with `deliver="inline"`. The mp4 is
     saved and the result says `[MCP resource saved to <path> …]`. End your reply with
     `MEDIA:<path>` on its own line.
   - If saving fails (too big, an error), give the `url` from the facts instead: it opens
     on the owner's phone over Tailscale.
   - Never use `deliver="telegram"` here: that sends through a different bot.
6. **Keep it short.** One or two sentences, then the media. Offer the live view as
   "Watch live: <live_url>" when it helps.

## What to call

| The user says | Do |
|---|---|
| "how are the cats?" / "show me" | `camera_status`, then `get_snapshot`. Reply: last seen + sightings in 6h, one honest line about the photo, `MEDIA:` the photo, "Watch live: <live_url>". |
| "anything new?" | `list_events` with `since_epoch` (the last time you checked, if you know it; else `hours=6`). For the newest real event, `get_event_frame` and attach it. Empty list = nothing new. |
| "send me the clip" | `get_last_clip` with `deliver="inline"`, attach the mp4. |
| "send me the recap" | `get_recap` with `deliver="inline"` (takes up to ~3 minutes; say so first if you can). Attach the mp4 and list the moments' times in one line. |
| "is the camera on?" | `camera_status`: paused, vision, dark, detector. |

## Scheduled digests (cron)

When this runs from a scheduled job:

1. Call `camera_status`.
2. If `paused` is true, reply exactly `[SILENT]`. The owner is home and switched it off.
3. Read the state file `~/ojogato/digest-state.txt` with `read_file` (it may not exist yet).
   Always read it before writing it, and write it with `write_file`, not shell redirects.
4. If the `ojogato` tools are missing or can't connect: if the state file already says
   `unreachable`, reply exactly `[SILENT]`. Otherwise write `unreachable` to it and send
   one line: "I can't reach the camera Mac (since <time>). If you didn't switch it off, it
   may be asleep or offline."
5. If it is reachable, write `ok` to the state file (only if it doesn't already say `ok`)
   and send the digest:
   - **Morning:** last seen, sightings in 12h, a live photo (`get_snapshot`), and
     "Watch live: <live_url>".
   - **Evening:** `get_recap` with `deliver="inline"`: one line with the number of moments
     and their times, then the video. If the recap is empty, say nothing was recognised
     today and attach a live photo instead.

## Owner on/off

The camera Mac has one switch, and you don't control it (the tools are read-only on
purpose, so an agent can never turn the monitoring off):

- `ojogato off` on the Mac (when home): camera, recording and alerts stop, and every
  scheduled digest here goes `[SILENT]`.
- `ojogato on` on the Mac (when leaving): everything resumes, digests included.

If asked to turn the camera on or off, explain this in one line.

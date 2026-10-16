# OpenClaw integration

Ojo de Gato works standalone over Telegram. Connecting it to an [OpenClaw](https://openclaw.ai) agent is the flagship extra: instead of running commands, you just ask your agent about the space and it answers in its own voice — backed entirely by the deterministic pipeline.

## What `register.sh` does

Run once, with explicit consent prompts along the way:

```sh
openclaw/register.sh
```

It wires four things into your OpenClaw installation. **Every file it touches gets a timestamped `.bak` backup first**, and the whole script is idempotent — re-running it updates in place rather than duplicating.

1. **Installs the skill.** A skill (SKILL.md + runner) lands in your OpenClaw workspace so the agent knows when and how to check the camera. The runner is thin — it just calls `~/.ojogato/bin/report.sh`; all logic stays in the pipeline.

2. **Appends an Ojo de Gato section to `~/.openclaw/workspace/AGENTS.md`.** This teaches the agent the ground rules: what the camera setup is, what the report output means, and what it may and may not claim (see "The honesty rule" below).

3. **Adds exec-approvals allowlist entries** for the ojogato scripts to agent `main`, so the agent can run the report without a manual approval prompt every time — and can run *only* those scripts, nothing broader.

4. **Optionally installs the two digest cron jobs** into `~/.openclaw/cron/jobs.json` — the 9am and 9pm digests, delivered through the agent. You're asked before this happens. Skip it and there are no scheduled digests; the watchdog still alerts you directly.

To undo everything, `openclaw/unregister.sh` reverses each step, restoring from the backups where appropriate.

## What it feels like

You message your agent on Telegram:

> **You:** how are the cats?
>
> **Agent:** Just checked — last activity 4 minutes ago, and it's been a busy afternoon: 23 motion moments in the last 6 hours. Sent you a live shot and a clip of the last movement. Live feed: http://your-mac.your-tailnet.ts.net:8889/cam (Tailscale on).

Behind that answer, the agent ran `report.sh`, which itself sent the snapshot and the ~9s last-movement clip to your Telegram, and printed the caption for the agent to relay. The agent adds phrasing; the pipeline supplies every fact. Morning and evening, the digest arrives the same way without your asking.

If the stream is down or the camera is paused, the report says so plainly and the agent passes that on — no papering over.

## The honesty rule: the agent never claims to see the images

This is the load-bearing rule in the AGENTS.md section, and it exists because the failure mode is so tempting: the agent sends you a photo of your cats, so it *feels* natural for it to say "they're curled up on the couch looking cozy."

It can't know that. In v1 no image ever enters the agent's context — the snapshot and clip go straight from ffmpeg to your Telegram. The agent sees only the text stats: minutes since last motion, motion-moment counts, whether the stream is up.

So the rule is: **report activity level and last-seen time; never invent positions, states, or descriptions.** "Last activity 4 minutes ago, pretty active this afternoon" is honest. "They're sleeping by the window" is fabrication, even if it happens to be true. The photos are for *your* eyes; the agent narrates the numbers.

(An optional, clearly-labeled LLM-vision layer that actually looks at frames is on the [roadmap](roadmap.md) — until then, any scene description from the agent is a bug.)

## Independence from the agent

Two properties worth knowing:

- **The watchdog does not depend on OpenClaw.** `heartbeat.sh` is plain launchd + curl, deliberately outside the agent. If the agent itself wedges, the pipeline breaks, or the room goes quiet too long, you get texted anyway — including an alert when the agent has stopped doing its scheduled checks.
- **Unregistering loses nothing but the voice.** After `unregister.sh`, reports, digests, clips, live view, and the watchdog all keep working in plain Telegram mode.

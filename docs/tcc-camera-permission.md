# Why headless camera access fails silently on macOS — and how Ojo de Gato fixes it

This is the single biggest trap in building a camera monitor on macOS. Everything works when you test in Terminal, then produces zero frames the moment launchd runs it. No error, no prompt, no log line — just an empty stream.

## The problem: TCC needs an app-bundle identity

macOS gates camera access through TCC (Transparency, Consent, and Control). A camera grant is not given to a *binary* — it is given to a **responsible bundle identity**, and it persists only if that identity is stable.

Three consequences, each of which bites in order:

1. **Terminal grants don't transfer to launchd.** When you run ffmpeg from Terminal, macOS attributes the camera request to Terminal — the "responsible process" — and prompts you to allow *Terminal* camera access. That grant belongs to `com.apple.Terminal`. When launchd later starts the same ffmpeg as a background LaunchAgent, there is no Terminal in the process tree. TCC finds no grant for the actual requester and denies access.

2. **The denial is silent.** ffmpeg's avfoundation input doesn't get a permission dialog in a background session — there is no UI context to show one. Capture simply produces nothing (or errors that read like a device problem, not a permission problem). You can burn hours checking device indexes before suspecting TCC.

3. **Unsigned binaries can't hold grants.** Even if you coax a prompt out of a bare binary, TCC ties the grant to the code's identity. An unsigned or ad-hoc-unsigned loose executable has no durable identity — grants get dropped or ignored, and every ffmpeg update would orphan them anyway.

## The fix: a real (tiny) app bundle, ad-hoc signed

Ojo de Gato's installer builds a minimal app bundle at `~/.ojogato/OjoGato.app`:

- **Bundle id:** `com.ojogato.capture` — this is the identity TCC stores the grant against.
- **`NSCameraUsageDescription`:** "Ojo de Gato streams your camera to you privately." — required in Info.plist for the permission dialog to appear at all.
- **Ad-hoc code signature** (`codesign -s -`) — no Apple Developer account needed. Ad-hoc signing is enough to give the bundle a stable code identity on the machine where it was signed, which is exactly what TCC needs.

The capture pipeline runs ffmpeg *through* this bundle, so every camera request — foreground or launchd — is attributed to `com.ojogato.capture`.

## The one-time Allow click

During `ojogato setup`, the installer runs a short **foreground** test capture through OjoGato.app. Because it's foreground, macOS can show the dialog:

> "OjoGato" would like to access the camera.
> *Ojo de Gato streams your camera to you privately.*

Click **Allow** once. The grant is stored against `com.ojogato.capture` and from then on the launchd services capture headlessly, across reboots, with the lid open and nobody logged into the GUI session doing anything.

This is why the setup step exists and can't be skipped: the grant can only be *created* with a foreground prompt, but once created it works everywhere.

## Troubleshooting

**Capture produces no frames after install**

Check whether the grant actually exists. In **System Settings → Privacy & Security → Camera** you should see **OjoGato** listed and enabled. At the database level, the grant is stored in TCC.db under the bundle id:

```sh
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, auth_value FROM access WHERE service='kTCCServiceCamera';"
```

You want a row for `com.ojogato.capture` with `auth_value` = 2 (allowed). (On newer macOS versions this file is heavily protected; the System Settings pane is the reliable view.)

**Grant looks present but capture still fails**

The signature may have changed (e.g. the bundle was rebuilt or moved). TCC treats a re-signed bundle as a new identity. Reset and re-grant:

```sh
tccutil reset Camera com.ojogato.capture
ojogato setup   # re-runs the foreground test capture -> new Allow prompt
```

**You clicked "Don't Allow" by mistake**

Same fix — `tccutil reset Camera com.ojogato.capture`, then re-run setup. macOS will not re-prompt an identity it has already denied until the record is reset.

**It works in Terminal but not from launchd**

That is this entire document. Verify the launchd plist invokes capture through `~/.ojogato/OjoGato.app`, not a bare ffmpeg path. `ojogato doctor` checks this wiring.

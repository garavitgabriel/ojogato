#!/bin/bash
# Ojo Gato installer — macOS v1.
# Usage: ./install.sh [--dry-run] [--link] [--yes]
#   --dry-run   print every action without doing anything
#   --link      dev mode: symlink src/bin scripts into ~/.ojogato/bin instead of copying
#   --yes       assume yes on prompts (non-destructive defaults)
#
# Idempotent: re-running upgrades scripts, templates, and binaries without
# clobbering ~/.ojogato/config.env or your recordings.

set -o pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
OJOGATO_HOME="$HOME/.ojogato"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
U=$(id -u)
SERVICES="com.ojogato.mediamtx com.ojogato.capture com.ojogato.record com.ojogato.motion com.ojogato.cleanup com.ojogato.heartbeat"

DRY_RUN=false
LINK_MODE=false
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --link)    LINK_MODE=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "install.sh: unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

step()  { printf '\n▸ %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '    ⚠ %s\n' "$*"; }
die()   { printf '✘ %s\n' "$*" >&2; exit 1; }
run() {
  if $DRY_RUN; then
    info "[dry-run] $*"
  else
    "$@"
  fi
}
confirm() {
  # confirm "question" -> 0 yes / 1 no. --yes answers yes.
  $ASSUME_YES && { info "$1 → yes (--yes)"; return 0; }
  $DRY_RUN && { info "[dry-run] would ask: $1"; return 0; }
  printf '    %s [y/N] ' "$1"
  read -r REPLY
  case "$REPLY" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- platform gate
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Ojo Gato v1 runs on macOS only (it is built on launchd + avfoundation)."
  echo "Linux/VPS support (RTSP camera input + systemd units) is on the roadmap:"
  echo "  docs/roadmap.md"
  exit 1
fi

echo "Ojo Gato installer"
$DRY_RUN  && echo "(dry-run: printing actions, changing nothing)"
$LINK_MODE && echo "(dev mode: scripts will be symlinked to the repo)"

# ---------------------------------------------------------------- preflight
step "Preflight checks"

OS_VER=$(sw_vers -productVersion 2>/dev/null)
OS_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
if [ -n "$OS_MAJOR" ] && [ "$OS_MAJOR" -lt 12 ] 2>/dev/null; then
  warn "macOS $OS_VER detected — Ojo Gato is tested on macOS 12+ (hardware H.264 encode, modern launchctl)."
  confirm "Continue anyway?" || die "Aborted."
else
  info "macOS $OS_VER — ok"
fi

CAM_COUNT=$(system_profiler SPCameraDataType 2>/dev/null | grep -c "Unique ID")
if [ "$CAM_COUNT" -ge 1 ] 2>/dev/null; then
  info "camera(s) detected: $CAM_COUNT"
else
  warn "no camera detected via system_profiler. Plug one in before setup, or continue and fix later."
  confirm "Continue without a camera?" || die "Aborted."
fi

FREE_GB=$(df -g /System/Volumes/Data 2>/dev/null | tail -1 | awk '{print $4}')
[ -z "$FREE_GB" ] && FREE_GB=$(df -g "$HOME" 2>/dev/null | tail -1 | awk '{print $4}')
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt 5 ] 2>/dev/null; then
  warn "only ${FREE_GB}GB free — the rolling recorder wants ~10GB+ of headroom."
  confirm "Continue anyway?" || die "Aborted."
elif [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt 15 ] 2>/dev/null; then
  warn "${FREE_GB}GB free — enough, but consider lowering OJOGATO_CAP_GB in config."
else
  info "disk: ${FREE_GB:-?}GB free — ok"
fi

if command -v tailscale >/dev/null 2>&1 || [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  info "Tailscale found — remote live view will be available"
else
  warn "Tailscale not found. The live stream stays LAN-only without it."
  warn "Install from https://tailscale.com/download — never expose ports 8888/8889 publicly."
fi

[ -d "$REPO_DIR/src/bin" ] || die "src/bin not found next to install.sh — run from the ojogato repo root."
[ -d "$REPO_DIR/src/templates" ] || die "src/templates not found — run from the ojogato repo root."

# ---------------------------------------------------------------- layout
step "Creating ~/.ojogato layout"
for d in bin recordings motionframes frames logs; do
  run mkdir -p "$OJOGATO_HOME/$d"
done

# ---------------------------------------------------------------- ffmpeg
step "Resolving ffmpeg"
ARCH=$(uname -m)
FFMPEG_DEST="$OJOGATO_HOME/bin/ffmpeg"
FFMPEG_SRC=""

if [ -x "$FFMPEG_DEST" ] && "$FFMPEG_DEST" -version >/dev/null 2>&1; then
  info "reusing existing $FFMPEG_DEST ($("$FFMPEG_DEST" -version 2>/dev/null | head -1 | awk '{print $3}'))"
else
  if command -v ffmpeg >/dev/null 2>&1; then
    FFMPEG_SRC=$(command -v ffmpeg)
    info "found ffmpeg on PATH: $FFMPEG_SRC"
  elif command -v brew >/dev/null 2>&1 && [ -x "$(brew --prefix 2>/dev/null)/bin/ffmpeg" ]; then
    FFMPEG_SRC="$(brew --prefix)/bin/ffmpeg"
    info "found Homebrew ffmpeg: $FFMPEG_SRC"
  fi

  if [ -n "$FFMPEG_SRC" ]; then
    run cp -f "$FFMPEG_SRC" "$FFMPEG_DEST"
    run chmod +x "$FFMPEG_DEST"
  elif [ "$ARCH" = "x86_64" ]; then
    info "no local ffmpeg — downloading static build from evermeet.cx (x86_64)"
    if $DRY_RUN; then
      info "[dry-run] curl -fsSL https://evermeet.cx/ffmpeg/getrelease/zip → unzip → $FFMPEG_DEST"
    else
      TMPD=$(mktemp -d) || die "mktemp failed"
      curl -fsSL --retry 2 -o "$TMPD/ffmpeg.zip" "https://evermeet.cx/ffmpeg/getrelease/zip" \
        || die "ffmpeg download failed — install manually (brew install ffmpeg) and re-run."
      unzip -oq "$TMPD/ffmpeg.zip" -d "$TMPD" || die "could not unzip ffmpeg archive"
      [ -f "$TMPD/ffmpeg" ] || die "ffmpeg binary not found inside archive"
      mv -f "$TMPD/ffmpeg" "$FFMPEG_DEST"
      chmod +x "$FFMPEG_DEST"
      rm -rf "$TMPD"
    fi
  else
    echo ""
    echo "✘ No ffmpeg found, and there is no canonical static-build download for Apple Silicon."
    echo "  Get ffmpeg one of these ways, then re-run ./install.sh:"
    echo "    • brew install ffmpeg                       (easiest)"
    echo "    • https://www.osxexperts.net                (static arm64 builds)"
    echo "    • https://ffmpeg.martin-riedl.de            (static arm64 builds)"
    exit 1
  fi

  if ! $DRY_RUN; then
    "$FFMPEG_DEST" -version >/dev/null 2>&1 || die "installed ffmpeg does not run ($FFMPEG_DEST)"
    info "ffmpeg ok: $("$FFMPEG_DEST" -version | head -1 | awk '{print $1, $2, $3}')"
  fi
fi

# ---------------------------------------------------------------- mediamtx
step "Resolving mediamtx"
MTX_DEST="$OJOGATO_HOME/bin/mediamtx"
if [ -x "$MTX_DEST" ] && "$MTX_DEST" --version >/dev/null 2>&1; then
  info "reusing existing $MTX_DEST ($("$MTX_DEST" --version 2>/dev/null | head -1)) — delete it to force a refetch"
else
  case "$ARCH" in
    arm64)  MTX_ARCH="darwin_arm64" ;;
    x86_64) MTX_ARCH="darwin_amd64" ;;
    *) die "unsupported architecture: $ARCH" ;;
  esac
  info "querying GitHub for the latest mediamtx release ($MTX_ARCH)"
  if $DRY_RUN; then
    info "[dry-run] curl api.github.com/repos/bluenviron/mediamtx/releases/latest → download *_${MTX_ARCH}.tar.gz → $MTX_DEST"
  else
    MTX_URL=$(curl -fsSL --retry 2 "https://api.github.com/repos/bluenviron/mediamtx/releases/latest" \
      | grep -o "https://github.com[^\"]*_${MTX_ARCH}\.tar\.gz" | head -1)
    [ -n "$MTX_URL" ] || die "could not find a ${MTX_ARCH} asset in the latest mediamtx release (GitHub rate limit?). Retry later."
    info "downloading $(basename "$MTX_URL")"
    TMPD=$(mktemp -d) || die "mktemp failed"
    curl -fsSL --retry 2 -o "$TMPD/mediamtx.tar.gz" "$MTX_URL" || die "mediamtx download failed"
    tar -xzf "$TMPD/mediamtx.tar.gz" -C "$TMPD" || die "could not extract mediamtx archive"
    MTX_BIN=$(find "$TMPD" -type f -name mediamtx | head -1)
    [ -n "$MTX_BIN" ] || die "mediamtx binary not found inside archive"
    mv -f "$MTX_BIN" "$MTX_DEST"
    chmod +x "$MTX_DEST"
    rm -rf "$TMPD"
    "$MTX_DEST" --version >/dev/null 2>&1 || die "installed mediamtx does not run"
    info "mediamtx ok: $("$MTX_DEST" --version 2>/dev/null | head -1)"
  fi
fi

# ---------------------------------------------------------------- scripts
if $LINK_MODE; then
  step "Linking src/bin → ~/.ojogato/bin (dev mode)"
else
  step "Copying src/bin → ~/.ojogato/bin"
fi
for f in "$REPO_DIR"/src/bin/*; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  dest="$OJOGATO_HOME/bin/$base"
  if $LINK_MODE; then
    run ln -sfn "$f" "$dest"
    info "linked $base"
  else
    run rm -f "$dest"            # never cp through a stale --link symlink into the repo
    run cp -f "$f" "$dest"
    run chmod +x "$dest"
    info "installed $base"
  fi
done
[ -f "$REPO_DIR/src/bin/ojogato" ] || warn "src/bin/ojogato missing from repo — CLI not installed"

# ---------------------------------------------------------------- app bundle
step "Building OjoGato.app (camera permission identity)"
APP="$OJOGATO_HOME/OjoGato.app"
APP_BIN="$APP/Contents/MacOS/ojogato-capture"
INFO_TMPL="$REPO_DIR/src/templates/Info.plist"

if [ ! -f "$INFO_TMPL" ]; then
  warn "src/templates/Info.plist not found — skipping app-bundle build (re-run install once it exists)."
else
  NEED_BUILD=false
  if [ ! -x "$APP_BIN" ]; then
    NEED_BUILD=true
  elif ! cmp -s "$FFMPEG_DEST" "$APP_BIN"; then
    NEED_BUILD=true
  else
    RENDERED=$(sed -e "s|@OJOGATO_HOME@|$OJOGATO_HOME|g" -e "s|@USER_HOME@|$HOME|g" "$INFO_TMPL")
    if [ "$RENDERED" != "$(cat "$APP/Contents/Info.plist" 2>/dev/null)" ]; then
      NEED_BUILD=true
    fi
  fi

  if ! $NEED_BUILD; then
    info "OjoGato.app already up to date — leaving it alone (preserves the camera grant)"
  else
    run mkdir -p "$APP/Contents/MacOS"
    if $DRY_RUN; then
      info "[dry-run] render Info.plist → $APP/Contents/Info.plist"
      info "[dry-run] cp ffmpeg → $APP_BIN"
      info "[dry-run] codesign --force --deep --sign - $APP"
    else
      sed -e "s|@OJOGATO_HOME@|$OJOGATO_HOME|g" -e "s|@USER_HOME@|$HOME|g" "$INFO_TMPL" > "$APP/Contents/Info.plist"
      rm -f "$APP_BIN"
      cp -f "$FFMPEG_DEST" "$APP_BIN"
      chmod +x "$APP_BIN"
      codesign --force --deep --sign - "$APP" 2>/dev/null || die "codesign failed — is Xcode CLT installed? (xcode-select --install)"
      info "built + ad-hoc signed $APP"
      warn "if this replaced an existing bundle, macOS may re-ask for camera permission (ojogato setup walks you through it)"
    fi
  fi
fi

# ---------------------------------------------------------------- templates
step "Rendering templates"

# Detect Tailscale hosts for mediamtx's webrtcAdditionalHosts (@OJOGATO_WEBRTC_HOSTS@).
TS_BIN=""
if command -v tailscale >/dev/null 2>&1; then
  TS_BIN=$(command -v tailscale)
elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi
# The template already carries the YAML brackets: webrtcAdditionalHosts: [@OJOGATO_WEBRTC_HOSTS@]
# so this value is the bare comma-separated host list (empty when no Tailscale).
WEBRTC_HOSTS=""
if [ -n "$TS_BIN" ]; then
  TS_IP=$("$TS_BIN" ip -4 2>/dev/null | head -1)
  TS_NAME=""
  if command -v python3 >/dev/null 2>&1; then
    TS_NAME=$("$TS_BIN" status --json 2>/dev/null | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))
except Exception: pass' 2>/dev/null)
  fi
  if [ -n "$TS_IP" ] && [ -n "$TS_NAME" ]; then
    WEBRTC_HOSTS="$TS_IP, $TS_NAME"
  elif [ -n "$TS_IP" ]; then
    WEBRTC_HOSTS="$TS_IP"
  elif [ -n "$TS_NAME" ]; then
    WEBRTC_HOSTS="$TS_NAME"
  fi
fi
info "webrtcAdditionalHosts → [${WEBRTC_HOSTS}]"

render() { # render <src> <dst>
  if $DRY_RUN; then
    info "[dry-run] render $(basename "$1") → $2"
  else
    sed -e "s|@OJOGATO_HOME@|$OJOGATO_HOME|g" \
        -e "s|@USER_HOME@|$HOME|g" \
        -e "s|@OJOGATO_WEBRTC_HOSTS@|$WEBRTC_HOSTS|g" "$1" > "$2"
    info "rendered $(basename "$2")"
  fi
}

run mkdir -p "$LAUNCH_AGENTS"
PLIST_COUNT=0
for t in "$REPO_DIR"/src/templates/com.ojogato.*.plist.tmpl; do
  [ -f "$t" ] || continue
  render "$t" "$LAUNCH_AGENTS/$(basename "$t" .tmpl)"
  PLIST_COUNT=$((PLIST_COUNT + 1))
done
[ "$PLIST_COUNT" -eq 6 ] || warn "expected 6 launchd plist templates, found $PLIST_COUNT"

if [ -f "$REPO_DIR/src/templates/mediamtx.yml.tmpl" ]; then
  render "$REPO_DIR/src/templates/mediamtx.yml.tmpl" "$OJOGATO_HOME/mediamtx.yml"
else
  warn "mediamtx.yml.tmpl missing — stream server has no config"
fi

if ! $DRY_RUN; then
  LEFTOVER=$(grep -l '@OJOGATO_HOME@\|@USER_HOME@\|@OJOGATO_WEBRTC_HOSTS@' "$LAUNCH_AGENTS"/com.ojogato.*.plist "$OJOGATO_HOME/mediamtx.yml" 2>/dev/null)
  [ -n "$LEFTOVER" ] && warn "unrendered placeholders remain in: $LEFTOVER"
fi

# ---------------------------------------------------------------- config
step "Config"
CONFIG="$OJOGATO_HOME/config.env"
if [ -f "$CONFIG" ]; then
  info "config.env exists — keeping it untouched"
  run chmod 600 "$CONFIG"
elif [ -f "$REPO_DIR/src/templates/config.env.example" ]; then
  run cp "$REPO_DIR/src/templates/config.env.example" "$CONFIG"
  run chmod 600 "$CONFIG"
  info "created config.env from example (chmod 600)"
else
  warn "config.env.example missing and no config.env present — runtime scripts will fail until it exists"
fi

# ---------------------------------------------------------------- install metadata
step "Recording install source (for 'ojogato update')"
if $DRY_RUN; then
  info "[dry-run] write $OJOGATO_HOME/.install-source ($REPO_DIR)"
  info "[dry-run] write $OJOGATO_HOME/.install-mode + copy uninstall.sh"
else
  echo "$REPO_DIR" > "$OJOGATO_HOME/.install-source"
  if $LINK_MODE; then echo "link" > "$OJOGATO_HOME/.install-mode"; else echo "copy" > "$OJOGATO_HOME/.install-mode"; fi
  if [ -f "$REPO_DIR/uninstall.sh" ]; then
    cp -f "$REPO_DIR/uninstall.sh" "$OJOGATO_HOME/uninstall.sh"
    chmod +x "$OJOGATO_HOME/uninstall.sh"
  fi
  info "done"
fi

# ---------------------------------------------------------------- services
step "Bootstrapping launchd services (gui/$U)"
for L in $SERVICES; do
  if $DRY_RUN; then
    info "[dry-run] launchctl bootout gui/$U/$L (ignore errors)"
  else
    launchctl bootout "gui/$U/$L" 2>/dev/null
  fi
done

if [ -f "$OJOGATO_HOME/PAUSED" ]; then
  warn "PAUSED flag present — camera services stay off. Loading heartbeat only; run 'ojogato on' when ready."
  BOOT_LIST="com.ojogato.heartbeat"
else
  BOOT_LIST="com.ojogato.mediamtx"
fi

boot() { # boot <label>
  if $DRY_RUN; then
    info "[dry-run] launchctl bootstrap gui/$U $LAUNCH_AGENTS/$1.plist"
  elif [ -f "$LAUNCH_AGENTS/$1.plist" ]; then
    launchctl bootstrap "gui/$U" "$LAUNCH_AGENTS/$1.plist" 2>/dev/null && info "started $1" || warn "$1 did not bootstrap (check $OJOGATO_HOME/logs)"
  else
    warn "$1.plist missing — not started"
  fi
}

for L in $BOOT_LIST; do boot "$L"; done
if [ ! -f "$OJOGATO_HOME/PAUSED" ]; then
  $DRY_RUN || sleep 2   # let mediamtx open 8554 before the publishers connect
  for L in com.ojogato.capture com.ojogato.record com.ojogato.motion com.ojogato.cleanup com.ojogato.heartbeat; do
    boot "$L"
  done
fi

# ---------------------------------------------------------------- handoff
step "Install complete"
info "home:     $OJOGATO_HOME"
info "cli:      $OJOGATO_HOME/bin/ojogato   (add ~/.ojogato/bin to your PATH for convenience)"
info "config:   $CONFIG"

if $DRY_RUN; then
  echo ""
  echo "▸ Dry-run finished — nothing was changed. Re-run without --dry-run to install."
  exit 0
fi

NEED_SETUP=false
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  TOK=$(. "$CONFIG" 2>/dev/null; echo "$OJOGATO_TELEGRAM_TOKEN")
  [ -z "$TOK" ] && NEED_SETUP=true
else
  NEED_SETUP=true
fi
FIRST_REC=$(ls "$OJOGATO_HOME/recordings"/*.mp4 2>/dev/null | head -1)
[ -z "$FIRST_REC" ] && NEED_SETUP=true

if [ -t 0 ]; then
  if $NEED_SETUP; then
    echo ""
    if $ASSUME_YES; then
      REPLY=y
    else
      printf '▸ Run the guided setup now (camera permission + Telegram + live URL)? [Y/n] '
      read -r REPLY
    fi
    case "$REPLY" in
      n|N|no|NO) echo "  Later, run: $OJOGATO_HOME/bin/ojogato setup" ;;
      *) exec "$OJOGATO_HOME/bin/ojogato" setup ;;
    esac
  else
    echo ""
    echo "▸ Existing setup detected. Check it with: $OJOGATO_HOME/bin/ojogato doctor"
  fi
else
  echo ""
  echo "▸ Next: run  $OJOGATO_HOME/bin/ojogato setup  in an interactive terminal."
fi

#!/data/data/com.termux/files/usr/bin/bash
# Optional: clone code-share into ~/cc-projects, mark it CC-Dev, npm install,
# and ensure cloudflared is present (used to tunnel the Git server). Idempotent.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

require_termux

REPO_URL="https://github.com/UnmanagedCode/code-share.git"
DIR="$HOME/cc-projects/code-share"

mkdir -p "$HOME/cc-projects"

# ── cloudflared ───────────────────────────────────────────────────────────────
if ! command -v cloudflared >/dev/null 2>&1; then
    log "Installing cloudflared (tunnel dependency for code-share)"
    pkg install -y cloudflared </dev/null
fi
ok "cloudflared at $(command -v cloudflared)"

# ── Clone or fast-forward ─────────────────────────────────────────────────────
if [ -d "$DIR/.git" ]; then
    log "code-share clone exists — fetching latest"
    ( cd "$DIR" && git fetch --quiet && git pull --ff-only --quiet )
    ok "code-share at $(git -C "$DIR" rev-parse --short HEAD)"
elif [ -e "$DIR" ]; then
    die "$DIR exists but is not a git checkout. Move or remove it, then re-run."
else
    log "Cloning $REPO_URL → $DIR"
    git clone --quiet "$REPO_URL" "$DIR"
    ok "Cloned at $(git -C "$DIR" rev-parse --short HEAD)"
fi

# ── Tag as CC-Dev group ───────────────────────────────────────────────────────
META_DIR="$HOME/cc-projects/.code-conductor/projects/code-share"
mkdir -p "$META_DIR"
printf '{\n  "group": "CC-Dev"\n}\n' > "$META_DIR/project.json"
ok "Marked code-share as CC-Dev group"

# ── npm install ───────────────────────────────────────────────────────────────
if ! command -v npm >/dev/null 2>&1; then
    if [ -d "$HOME/claude-code-android/bin" ]; then
        export PATH="$HOME/claude-code-android/bin:$PATH"
    fi
fi
command -v npm >/dev/null 2>&1 || die "npm not on PATH. Did the Claude CLI install step finish?"
log "Installing code-share deps (npm install)"
( cd "$DIR" && npm install --no-audit --no-fund )

ok "code-share ready at $DIR"

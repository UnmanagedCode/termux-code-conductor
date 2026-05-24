#!/data/data/com.termux/files/usr/bin/bash
# Optional: clone termux-playwright-harness into ~/cc-projects and mark it as
# part of the CC-Dev group. The harness provides Playwright + Termux-Chromium
# glue for visual UI debugging from a phone. Used as a sibling import by
# other ~/cc-projects/ apps. Idempotent.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

require_termux

HARNESS_URL="https://github.com/UnmanagedCode/termux-playwright-harness.git"
HARNESS_DIR="$HOME/cc-projects/termux-playwright-harness"

mkdir -p "$HOME/cc-projects"

# Termux Chromium is the actual browser the harness drives via playwright-core.
# It lives in the x11-repo (not the default termux-main), so enable that first.
if ! command -v chromium-browser >/dev/null 2>&1; then
    if ! dpkg -s x11-repo >/dev/null 2>&1; then
        log "Enabling Termux x11-repo (provides the chromium package)"
        pkg install -y x11-repo </dev/null
        pkg update -y </dev/null 2>&1 || true
    fi
    log "Installing Termux chromium package"
    pkg install -y chromium </dev/null
fi
command -v chromium-browser >/dev/null 2>&1 \
    || die "chromium-browser still not found after install. Try 'pkg install -y x11-repo chromium' manually."
ok "chromium-browser at $(command -v chromium-browser)"

if [ -d "$HARNESS_DIR/.git" ]; then
    log "Harness clone exists — fetching latest"
    ( cd "$HARNESS_DIR" && git fetch --quiet && git pull --ff-only --quiet )
    ok "termux-playwright-harness at $(git -C "$HARNESS_DIR" rev-parse --short HEAD)"
elif [ -e "$HARNESS_DIR" ]; then
    die "$HARNESS_DIR exists but is not a git checkout. Move or remove it, then re-run."
else
    log "Cloning $HARNESS_URL → $HARNESS_DIR"
    git clone --quiet "$HARNESS_URL" "$HARNESS_DIR"
    ok "Cloned at $(git -C "$HARNESS_DIR" rev-parse --short HEAD)"
fi

# Assign to the CC-Dev group via Code Conductor's central store at
# <cc-projects>/.code-conductor/projects/<name>/project.json.
META_DIR="$HOME/cc-projects/.code-conductor/projects/termux-playwright-harness"
mkdir -p "$META_DIR"
cat > "$META_DIR/project.json" <<'EOF'
{
  "group": "CC-Dev"
}
EOF
ok "Marked termux-playwright-harness as CC-Dev group"

if ! command -v npm >/dev/null 2>&1; then
    if [ -d "$HOME/claude-code-android/bin" ]; then
        export PATH="$HOME/claude-code-android/bin:$PATH"
    fi
fi
command -v npm >/dev/null 2>&1 || die "npm not on PATH. Did the Claude CLI install step finish?"

log "Installing harness deps (npm install)"
( cd "$HARNESS_DIR" && npm install --no-audit --no-fund )
ok "termux-playwright-harness ready at $HARNESS_DIR"

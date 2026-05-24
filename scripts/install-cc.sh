#!/data/data/com.termux/files/usr/bin/bash
# Clone Code Conductor (the multi-agent orch app), install deps, start the
# server in the background with PROJECTS_ROOT=~/cc-projects, and mark the
# clone as belonging to the CC-Dev group inside Code Conductor's UI.
# Idempotent.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

require_termux

CC_URL="https://github.com/UnmanagedCode/code-conductor.git"
CC_PROJECTS_DIR="$HOME/cc-projects"
CC_DIR="$CC_PROJECTS_DIR/code-conductor"
SERVER_LOG="$CC_DIR/server.log"
CC_LOCAL_URL="http://127.0.0.1:8787"

mkdir -p "$CC_PROJECTS_DIR"

# Drop the vendored workspace-conventions CLAUDE.md at the cc-projects root
# (only if not already present — never overwrite the user's own customizations).
if [ ! -f "$CC_PROJECTS_DIR/CLAUDE.md" ]; then
    cp "$HERE/vendor/cc-projects-CLAUDE.md" "$CC_PROJECTS_DIR/CLAUDE.md"
    # Record the baseline so `cc update` can later tell user edits apart
    # from upstream changes.
    state_dir="$HOME/.cache/code-conductor-bootstrap"
    mkdir -p "$state_dir"
    cp "$HERE/vendor/cc-projects-CLAUDE.md" "$state_dir/CLAUDE.md.installed"
    ok "Installed $CC_PROJECTS_DIR/CLAUDE.md (workspace conventions)"
fi

# Clone or update Code Conductor
if [ -d "$CC_DIR/.git" ]; then
    log "Code Conductor clone exists — fetching latest"
    ( cd "$CC_DIR" && git fetch --quiet && git pull --ff-only --quiet )
    ok "code-conductor at $(git -C "$CC_DIR" rev-parse --short HEAD)"
elif [ -e "$CC_DIR" ]; then
    die "$CC_DIR exists but is not a git checkout. Move or remove it, then re-run."
else
    log "Cloning $CC_URL → $CC_DIR"
    git clone --quiet "$CC_URL" "$CC_DIR"
    ok "Cloned at $(git -C "$CC_DIR" rev-parse --short HEAD)"
fi

# Assign to the CC-Dev group. The group is metadata stored in
# <project>/.code-conductor/project.json — Code Conductor reads it on list,
# no filesystem nesting needed.
META_DIR="$CC_DIR/.code-conductor"
mkdir -p "$META_DIR"
cat > "$META_DIR/project.json" <<'EOF'
{
  "group": "CC-Dev"
}
EOF
ok "Marked code-conductor as CC-Dev group"

# Ensure npm is on PATH (Claude CLI install step adds it to ~/.bashrc but
# the current shell hasn't sourced that yet during a fresh bootstrap)
if ! command -v npm >/dev/null 2>&1; then
    if [ -d "$HOME/claude-code-android/bin" ]; then
        export PATH="$HOME/claude-code-android/bin:$PATH"
    fi
fi
command -v npm >/dev/null 2>&1 || die "npm not on PATH. Did the Claude CLI install step finish?"

log "Installing Code Conductor deps (npm install)"
( cd "$CC_DIR" && npm install --no-audit --no-fund )
ok "npm install complete"

# Stop any existing server cleanly before restarting
if pgrep -f "node $CC_DIR/server.js" >/dev/null 2>&1; then
    log "Existing Code Conductor server found, stopping it"
    pkill -f "node $CC_DIR/server.js" || true
    sleep 1
fi

log "Starting Code Conductor server in background (PROJECTS_ROOT=$CC_PROJECTS_DIR)"
( cd "$CC_DIR" && PROJECTS_ROOT="$CC_PROJECTS_DIR" nohup npm start >"$SERVER_LOG" 2>&1 & )

for i in $(seq 1 10); do
    sleep 1
    if curl -sf "$CC_LOCAL_URL/" >/dev/null 2>&1; then
        ok "Code Conductor running at $CC_LOCAL_URL  (logs: $SERVER_LOG)"
        exit 0
    fi
done

warn "Code Conductor did not respond on $CC_LOCAL_URL within 10s. Tail of $SERVER_LOG:"
tail -n 30 "$SERVER_LOG" >&2 || true
die "Code Conductor failed to start. Inspect $SERVER_LOG."

#!/data/data/com.termux/files/usr/bin/bash
# Install Claude Code CLI under ~/claude-code-android via the vendored
# openclaw-android-based installer. Idempotent: if claude -v already works,
# skips immediately.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

require_termux

CLAUDE_BIN="$HOME/claude-code-android/bin/claude"

if [ -x "$CLAUDE_BIN" ] && "$CLAUDE_BIN" -v >/dev/null 2>&1; then
    ok "Claude CLI already installed ($("$CLAUDE_BIN" -v 2>&1 | head -1))"
    exit 0
fi

log "Running vendored claude-install.sh (12-step glibc-runner + Node 22 + claude install)"
bash "$HERE/vendor/claude-install.sh"

if [ -x "$CLAUDE_BIN" ] && "$CLAUDE_BIN" -v >/dev/null 2>&1; then
    ok "Claude CLI installed: $("$CLAUDE_BIN" -v 2>&1 | head -1)"
else
    die "Installer finished but $CLAUDE_BIN is not runnable. Check ~/claude-code-android/install.log"
fi

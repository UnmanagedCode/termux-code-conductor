#!/data/data/com.termux/files/usr/bin/bash
# Recurring reconciler: ensure bin/claude-mux exists and is current.
#
# bin/claude-mux is the target dohshim rewrites CLAUDE_CODE_EXECPATH to, so
# Claude Code's Bash-tool grep/find shell functions resolve to the bundled
# ripgrep/bfs. write_wrappers() (vendor/claude-install.sh) emits it on a fresh
# CLI install, but `cc upgrade` npm-upgrades the package without regenerating
# wrappers — so an install that predates this feature would lack the shim. This
# migration (re)writes it from the shared lib.sh emitter, byte-identical to
# write_wrappers(). Atomic write (temp + rename); never touches other wrappers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

INSTALL_DIR="$HOME/claude-code-android"
BIN_DIR="$INSTALL_DIR/bin"
NPM_PREFIX="$INSTALL_DIR/npm-prefix"
CLAUDE_EXE="$NPM_PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
GLIBC_LDSO="${PREFIX:-/data/data/com.termux/files/usr}/glibc/lib/ld-linux-aarch64.so.1"
GLIBC_LIBDIR="${PREFIX:-/data/data/com.termux/files/usr}/glibc/lib"
SH="${PREFIX:-/data/data/com.termux/files/usr}/bin/bash"
MUX="$BIN_DIR/claude-mux"

# Only on a real Claude install (claude.exe present). Never bootstrap it here.
[ -f "$CLAUDE_EXE" ] || exit 0

# Already present and carrying the argv0-dispatch line → nothing to do.
[ -f "$MUX" ] && grep -qF -- '--argv0 "$_a0"' "$MUX" && exit 0

log "bin/claude-mux missing or outdated — regenerating"
_tmp="$(mktemp "$BIN_DIR/.claude-mux.XXXXXX")"
claude_mux_wrapper "$SH" "$GLIBC_LDSO" "$GLIBC_LIBDIR" "$CLAUDE_EXE" > "$_tmp"
if ! grep -qF -- '--argv0 "$_a0"' "$_tmp"; then
    rm -f "$_tmp"
    warn "claude-mux emitter produced unexpected content — leaving existing shim untouched"
    exit 1
fi
chmod 755 "$_tmp"
mv -f "$_tmp" "$MUX"
ok "Wrote $MUX"

#!/data/data/com.termux/files/usr/bin/bash
# Install, patch, or remove the dns-doh DNS-over-HTTPS fallback for Claude Code.
#
# A C LD_PRELOAD shim intercepts getaddrinfo() and falls back to DoH via curl
# on port 443 (Cloudflare 1.1.1.1) when the system resolver fails. Zero overhead
# on healthy networks (fast path tries the system resolver first).
#
# Wrapper-regeneration note: write_wrappers() in vendor/claude-install.sh only
# fires during a full fresh Claude CLI install (install-claude-cli.sh exits early
# if claude -v works). cc upgrade only npm-upgrades the package and does NOT
# regenerate the wrapper. The auto-heal hook in update.sh covers the rare case
# where INSTALLER_CHANGED forces a full reinstall; for a manual wipe + reinstall
# of ~/claude-code-android, re-run: cc install dns-doh
#
# Usage:
#   install-dns-doh.sh              # full install (compile + patch wrapper)
#   install-dns-doh.sh --patch-only # re-apply wrapper patch only (no compile)
#   install-dns-doh.sh --uninstall  # remove shim and wrapper patch

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
require_termux

MODE=install
case "${1:-}" in
    --patch-only) MODE=patch ;;
    --uninstall)  MODE=uninstall ;;
    "") MODE=install ;;
    *) die "Unknown argument: ${1}. Usage: $0 [--patch-only|--uninstall]" ;;
esac

SHIM_SRC="$HERE/dns-doh/dohshim.c"
SHIM_DIR="$HOME/claude-code-android/dns-doh"
SHIM_SO="$SHIM_DIR/dohshim.so"
WRAPPER="$HOME/claude-code-android/bin/claude"

MARKER_START='# >>> dns-doh shim >>>'
MARKER_END='# <<< dns-doh shim <<<'

# ── Wrapper helpers ───────────────────────────────────────────────────────────

patch_wrapper() {
    [ -f "$WRAPPER" ] || die "Claude wrapper not found at $WRAPPER — install Claude CLI first."
    if grep -qF "$MARKER_START" "$WRAPPER"; then
        ok "Claude wrapper already patched — skipping"
        return
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v start="$MARKER_START" -v end="$MARKER_END" -v shim="$SHIM_SO" '
        /^unset LD_PRELOAD$/ {
            print
            print ""
            print start
            print "_DOH_SHIM=\"" shim "\""
            print "[ -f \"$_DOH_SHIM\" ] && export LD_PRELOAD=\"$_DOH_SHIM\""
            print end
            next
        }
        { print }
    ' "$WRAPPER" > "$tmp"
    # Verify the insertion actually landed before committing the rewrite.
    if ! grep -qF "$MARKER_START" "$tmp"; then
        rm -f "$tmp"
        die "Anchor line 'unset LD_PRELOAD' not found in wrapper — cannot patch (wrapper format may have changed). Wrapper left unmodified."
    fi
    mv "$tmp" "$WRAPPER"
    chmod 755 "$WRAPPER"
    ok "Patched claude wrapper at $WRAPPER"
}

unpatch_wrapper() {
    if [ ! -f "$WRAPPER" ]; then
        log "Claude wrapper not found — nothing to unpatch"
        return
    fi
    if ! grep -qF "$MARKER_START" "$WRAPPER"; then
        log "dns-doh block not in wrapper — nothing to remove"
        return
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v start="$MARKER_START" -v end="$MARKER_END" '
        $0 == start { skip=1; next }
        $0 == end   { skip=0; next }
        skip        { next }
        { print }
    ' "$WRAPPER" > "$tmp"
    mv "$tmp" "$WRAPPER"
    chmod 755 "$WRAPPER"
    ok "Removed dns-doh block from claude wrapper"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
if [ "$MODE" = "uninstall" ]; then
    unpatch_wrapper
    if [ -f "$SHIM_SO" ]; then
        rm -f "$SHIM_SO"
        rmdir "$SHIM_DIR" 2>/dev/null || true
        ok "Removed $SHIM_SO"
    else
        log "Shim not found at $SHIM_SO — nothing to remove"
    fi
    log "dns-doh uninstalled. Run 'pkg remove clang' if clang is no longer needed."
    exit 0
fi

# ── Patch-only ────────────────────────────────────────────────────────────────
if [ "$MODE" = "patch" ]; then
    [ -f "$SHIM_SO" ] \
        || die "Shim not found at $SHIM_SO — run 'cc install dns-doh' to (re)install."
    patch_wrapper
    exit 0
fi

# ── Full install ──────────────────────────────────────────────────────────────

# 1. Ensure clang (build dep, pulled in only for this optional feature)
if ! command -v clang >/dev/null 2>&1; then
    log "Installing clang (build dependency for dns-doh)"
    pkg install -y clang </dev/null \
        || die "Failed to install clang. Try 'pkg install -y clang' manually."
fi
command -v clang >/dev/null 2>&1 || die "clang still not found after install."
ok "clang at $(command -v clang)"

# 2. Confirm curl present (hard dep from core install step 2)
command -v curl >/dev/null 2>&1 \
    || die "curl not found — is the Claude CLI core install complete?"
ok "curl at $(command -v curl)"

# 3. Compile — must succeed before we touch the wrapper
[ -f "$SHIM_SRC" ] \
    || die "Source not found at $SHIM_SRC — is the bootstrap repo intact?"
mkdir -p "$SHIM_DIR"
log "Compiling dns-doh shim"
clang -shared -fPIC -nostdlib -fno-stack-protector -O2 \
    "$SHIM_SRC" -o "$SHIM_SO" \
    || die "Compile failed — see clang output above. Wrapper NOT patched."

# 4. Validate ELF before patching the wrapper
file "$SHIM_SO" | grep -q 'ELF' \
    || die "Compiled output at $SHIM_SO is not a valid ELF. Wrapper NOT patched."
ok "Built $SHIM_SO ($(wc -c < "$SHIM_SO" | tr -d ' ') bytes, $(file -b "$SHIM_SO" | cut -d, -f1))"

# 5. Patch wrapper (only after successful compile + ELF validation)
patch_wrapper

ok "dns-doh installed."
log "  Validate: CLAUDE_DOH_FORCE=1 claude --version"
log "  Uninstall: bash $HERE/install-dns-doh.sh --uninstall"

#!/data/data/com.termux/files/usr/bin/bash
# Install, patch, or remove the dns-doh DNS-over-HTTPS fallback for Claude Code
# and Node.
#
# A C LD_PRELOAD shim intercepts getaddrinfo() and falls back to DoH via curl
# on port 443 (Cloudflare 1.1.1.1) when the system resolver fails. Zero overhead
# on healthy networks (fast path tries the system resolver first). The shim also
# interposes connect(): Bun >= 1.4.0's internal c-ares resolver bypasses
# getaddrinfo and hits a dead 127.0.0.1:53 on Android (no /etc/resolv.conf), so
# the shim redirects that connect to a loopback responder that answers via the
# same DoH path. See dohshim.c's "connect() DoH fallback" section.
#
# struct-ABI note: both the claude wrapper (Bun claude.exe) and the node wrapper
# (node.real) launch *glibc* binaries via glibc-runner's ld.so. The wrappers
# `unset LD_PRELOAD` precisely because Termux's inherited LD_PRELOAD points at
# the *bionic* libtermux-exec.so, whose getaddrinfo would return a bionic-ABI
# `struct addrinfo` (different field order) into a glibc consumer → crash. Our
# dohshim.so is compiled against the glibc addrinfo layout, so re-exporting ONLY
# dohshim.so into either glibc process is correct for both. We must never
# re-introduce libtermux-exec.so here. (dohshim.c documents the glibc layout.)
#
# Wrapper-regeneration note: write_wrappers() in vendor/claude-install.sh only
# fires during a full fresh Claude CLI install (install-claude-cli.sh exits early
# if claude -v works). It regenerates BOTH bin/claude and bin/node, wiping any
# patch. cc upgrade only npm-upgrades the package and does NOT regenerate the
# wrappers. The recurring migrations (0001 claude, 0003 node) re-apply the patch
# after any regeneration; for a manual wipe + reinstall of ~/claude-code-android,
# re-run: cc install dns-doh
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
NODE_WRAPPER="$HOME/claude-code-android/bin/node"

# DOH_MARKER_START/END and the shim-block emitter live in lib.sh — shared with
# vendor/claude-install.sh's write_wrappers() so both patchers agree on the
# exact block text.

# ── Wrapper helpers ───────────────────────────────────────────────────────────
# Both helpers take the wrapper path as $1. The marker block re-exports ONLY the
# glibc dohshim.so (never bionic libtermux-exec.so), anchored to the wrapper's
# own `unset LD_PRELOAD` line — identical for the claude and node wrappers.

# Make a one-time pristine backup before the first patch (idempotent: never
# overwrites an existing backup, so an already-patched wrapper can't clobber the
# clean original). Enables a file-restore rollback alongside --uninstall.
backup_wrapper() {
    local wrapper="$1" label="$2"
    [ -f "$wrapper" ] || return 0
    if [ ! -e "$wrapper.pre-dns-doh.bak" ]; then
        cp "$wrapper" "$wrapper.pre-dns-doh.bak"
        ok "Backed up $label wrapper → $wrapper.pre-dns-doh.bak"
    fi
}

patch_wrapper() {
    local wrapper="$1" label="$2"
    [ -f "$wrapper" ] || die "$label wrapper not found at $wrapper — install Claude CLI first."
    if grep -qF "$DOH_MARKER_START" "$wrapper"; then
        ok "$label wrapper already patched — skipping"
        return
    fi
    backup_wrapper "$wrapper" "$label"
    local tmp
    tmp="$(mktemp)"
    dns_doh_insert_block "$SHIM_SO" < "$wrapper" > "$tmp"
    # Verify the insertion actually landed before committing the rewrite.
    if ! grep -qF "$DOH_MARKER_START" "$tmp"; then
        rm -f "$tmp"
        die "Anchor line 'unset LD_PRELOAD' not found in $label wrapper — cannot patch (wrapper format may have changed). Wrapper left unmodified."
    fi
    mv "$tmp" "$wrapper"
    chmod 755 "$wrapper"
    ok "Patched $label wrapper at $wrapper"
}

unpatch_wrapper() {
    local wrapper="$1" label="$2"
    if [ ! -f "$wrapper" ]; then
        log "$label wrapper not found — nothing to unpatch"
        return
    fi
    if ! grep -qF "$DOH_MARKER_START" "$wrapper"; then
        log "dns-doh block not in $label wrapper — nothing to remove"
        return
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v start="$DOH_MARKER_START" -v end="$DOH_MARKER_END" '
        $0 == start { skip=1; next }
        $0 == end   { skip=0; next }
        skip        { next }
        { print }
    ' "$wrapper" > "$tmp"
    mv "$tmp" "$wrapper"
    chmod 755 "$wrapper"
    ok "Removed dns-doh block from $label wrapper"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
if [ "$MODE" = "uninstall" ]; then
    unpatch_wrapper "$WRAPPER" "claude"
    unpatch_wrapper "$NODE_WRAPPER" "node"
    rm -f "$WRAPPER.pre-dns-doh.bak" "$NODE_WRAPPER.pre-dns-doh.bak"
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
    patch_wrapper "$WRAPPER" "claude"
    patch_wrapper "$NODE_WRAPPER" "node"
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

# 5. Patch wrappers (only after successful compile + ELF validation)
patch_wrapper "$WRAPPER" "claude"
patch_wrapper "$NODE_WRAPPER" "node"

ok "dns-doh installed."
log "  Validate: CLAUDE_DOH_FORCE=1 claude --version"
log "  Uninstall: bash $HERE/install-dns-doh.sh --uninstall"

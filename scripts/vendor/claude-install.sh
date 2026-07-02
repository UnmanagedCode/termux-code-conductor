#!/data/data/com.termux/files/usr/bin/bash
# claude-code-android — minimal Claude Code + tmux installer for Termux/Android.
#
# Approach and rationale: ~/.claude/plans/i-want-you-to-drifting-emerson.md
# Background on why glibc-runner is needed: ~/notes/openclaw-android-anatomy.md
# DNS-over-TCP fix background: ~/notes/glibc-runner-dns-fix.md
#
# This script clones the upstream openclaw-android repo for the canonical
# glibc-compat.js patch only — it does NOT run the upstream installer or
# install OpenClaw, clawdhub, Chromium, etc. Everything it produces lives under
# $INSTALL_DIR. Idempotent and resumable: every step checks its actual artifact
# and skips if already present.
set -euo pipefail

# ── Constants ───────────────────────────────────────────────────────────────

INSTALL_DIR="$HOME/claude-code-android"
REPO_DIR="$INSTALL_DIR/repo"
CACHE_DIR="$INSTALL_DIR/cache"
NODE_DIR="$INSTALL_DIR/node"
PATCH_DIR="$INSTALL_DIR/patches"
BIN_DIR="$INSTALL_DIR/bin"
NPM_PREFIX="$INSTALL_DIR/npm-prefix"
STATE_DIR="$INSTALL_DIR/.state"

REPO_URL="https://github.com/AidanPark/openclaw-android.git"
REPO_REF="main"

NODE_VERSION="22.22.0"
NODE_TARBALL="node-v${NODE_VERSION}-linux-arm64.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
NODE_SHASUMS_URL="https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"

CLAUDE_PKG="@anthropic-ai/claude-code"
GLIBC_LDSO="${PREFIX:-/data/data/com.termux/files/usr}/glibc/lib/ld-linux-aarch64.so.1"
GLIBC_LIBDIR="${PREFIX:-/data/data/com.termux/files/usr}/glibc/lib"

BASHRC_MARK_START="# >>> claude-code-android (PATH only) >>>"
BASHRC_MARK_END="# <<< claude-code-android (PATH only) <<<"

# DOH_MARKER_START/END and the dns_doh_shim_block/dns_doh_insert_block
# emitters are shared with install-dns-doh.sh via lib.sh, so write_wrappers()
# below can bake an already-patched wrapper. lib.sh's own log/ok/warn/die are
# harmlessly shadowed by this file's Logging section right below.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPTS_DIR/lib.sh"
SHIM_SO="$INSTALL_DIR/dns-doh/dohshim.so"

# ── Logging ─────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m'; C_NC=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_NC=''
fi

step()  { printf '\n%s[%s] %s%s\n' "$C_BLD" "$1" "$2" "$C_NC"; }
ok()    { printf '  %s[OK]%s   %s\n'   "$C_GRN" "$C_NC" "$*"; }
skip()  { printf '  %s[SKIP]%s %s\n'   "$C_GRN" "$C_NC" "$*"; }
info()  { printf '  %s[INFO]%s %s\n'   "$C_BLU" "$C_NC" "$*"; }
warn()  { printf '  %s[WARN]%s %s\n'   "$C_YEL" "$C_NC" "$*" >&2; }
die()   { printf '  %s[FAIL]%s %s\n'   "$C_RED" "$C_NC" "$*" >&2; exit 1; }

# ── Step 1: Preflight ───────────────────────────────────────────────────────

preflight() {
    step 1 "Preflight"
    [ -n "${PREFIX:-}" ] || die "PREFIX is not set; this script must run inside Termux."
    [ -x "$PREFIX/bin/bash" ] || die "Expected $PREFIX/bin/bash to exist."
    local arch; arch=$(uname -m)
    [ "$arch" = "aarch64" ] || die "Architecture $arch not supported (need aarch64)."

    local free_mb; free_mb=$(df "$PREFIX" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 1500 ]; then
        die "Insufficient free space on \$PREFIX: ${free_mb}MB (need >=1500MB)."
    fi
    ok "aarch64 Termux, ${free_mb:-?}MB free on \$PREFIX"

    mkdir -p "$INSTALL_DIR" "$CACHE_DIR" "$PATCH_DIR" "$BIN_DIR" "$STATE_DIR" "$NPM_PREFIX"
    ok "Directory tree ready at $INSTALL_DIR"
}

# ── Step 2: Termux packages ─────────────────────────────────────────────────

install_pkgs() {
    step 2 "Termux packages (git, tmux, pacman, curl, coreutils)"
    local need=0
    for cmd in git tmux pacman curl sha256sum tar xz; do
        command -v "$cmd" >/dev/null 2>&1 || { need=1; break; }
    done
    if [ "$need" = 0 ] && [ -f "$STATE_DIR/pkgs-ok" ]; then
        skip "All required packages already present"
        return
    fi
    pkg install -y git tmux pacman curl coreutils xz-utils
    for cmd in git tmux pacman curl sha256sum tar xz; do
        command -v "$cmd" >/dev/null 2>&1 || die "Missing required command after install: $cmd"
    done
    touch "$STATE_DIR/pkgs-ok"
    ok "Packages installed and verified"
}

# ── Step 3: Clone or update upstream repo ──────────────────────────────────

clone_repo() {
    step 3 "Clone upstream openclaw-android repo (for the canonical glibc-compat.js)"
    if [ -d "$REPO_DIR/.git" ]; then
        info "Existing clone — fetching $REPO_REF"
        git -C "$REPO_DIR" fetch --depth 1 origin "$REPO_REF"
        git -C "$REPO_DIR" reset --hard FETCH_HEAD
        ok "Updated to $(git -C "$REPO_DIR" rev-parse --short HEAD)"
    else
        # If $REPO_DIR exists but isn't a git repo (failed prior clone), wipe and retry.
        [ -e "$REPO_DIR" ] && rm -rf "$REPO_DIR"
        git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$REPO_DIR"
        ok "Cloned at $(git -C "$REPO_DIR" rev-parse --short HEAD)"
    fi
}

# ── Step 4: Validate required upstream files ───────────────────────────────

validate_upstream() {
    step 4 "Validate required upstream files exist"
    # Upstream repo root contains patches/ and scripts/ directly (no installer/ prefix —
    # the local ~/.openclaw-android/installer/ dir is the *installed* layout, not the
    # repo layout).
    local required=(
        "$REPO_DIR/patches/glibc-compat.js"
        "$REPO_DIR/scripts/install-glibc.sh"
        "$REPO_DIR/scripts/install-nodejs.sh"
    )
    local f
    for f in "${required[@]}"; do
        [ -f "$f" ] || die "Upstream layout changed — missing: $f"
        [ -s "$f" ] || die "Upstream file is empty: $f"
    done
    ok "All ${#required[@]} required upstream files present and non-empty"
}

# ── Step 5: Install glibc-runner via pacman ────────────────────────────────

install_glibc() {
    step 5 "Install glibc-runner (provides ld-linux-aarch64.so.1)"
    if [ -x "$GLIBC_LDSO" ]; then
        skip "glibc-runner already installed ($GLIBC_LDSO)"
        # Make sure the hosts file is in place even on skip — it's the cheap fix
        # that prevents localhost from being resolved as 0.0.0.0.
        ensure_glibc_hosts
        touch "$STATE_DIR/glibc-ok"
        return
    fi

    local pacman_conf="$PREFIX/etc/pacman.conf"
    local sig_patched=0
    if [ -f "$pacman_conf" ] && ! grep -q '^SigLevel = Never' "$pacman_conf"; then
        cp "$pacman_conf" "$pacman_conf.bak"
        sed -i 's/^SigLevel\s*=.*/SigLevel = Never/' "$pacman_conf"
        sig_patched=1
        info "Applied SigLevel = Never workaround (GPGME bug on some devices)"
    fi

    info "Initializing pacman keyring (may take a moment)..."
    pacman-key --init 2>/dev/null || true
    pacman-key --populate 2>/dev/null || true

    info "Upgrading pacman local database (fresh installs ship a pre-4.2 placeholder)..."
    pacman-db-upgrade 2>/dev/null || true

    info "Installing glibc-runner via pacman..."
    if ! pacman -Sy glibc-runner --noconfirm --assume-installed bash,patchelf,resolv-conf; then
        [ "$sig_patched" = 1 ] && [ -f "$pacman_conf.bak" ] && mv "$pacman_conf.bak" "$pacman_conf"
        die "pacman failed to install glibc-runner"
    fi

    if [ "$sig_patched" = 1 ] && [ -f "$pacman_conf.bak" ]; then
        mv "$pacman_conf.bak" "$pacman_conf"
        ok "Restored original $pacman_conf"
    fi

    [ -x "$GLIBC_LDSO" ] || die "glibc dynamic linker still missing after install: $GLIBC_LDSO"
    ensure_glibc_hosts
    touch "$STATE_DIR/glibc-ok"
    ok "glibc-runner installed; ld.so available at $GLIBC_LDSO"
}

ensure_glibc_hosts() {
    local glibc_etc="$PREFIX/glibc/etc"
    [ -d "$glibc_etc" ] || return 0
    if [ ! -f "$glibc_etc/hosts" ]; then
        cat > "$glibc_etc/hosts" <<'HOSTS'
127.0.0.1 localhost localhost.localdomain
::1 localhost ip6-localhost ip6-loopback
HOSTS
        ok "Created $glibc_etc/hosts (localhost resolution for glibc)"
    fi
}

# ── Step 6: Download Node tarball (cached, resumable, sha256-verified) ────

verify_node_sha() {
    local tarball="$1" shasums="$2"
    local expected actual
    expected=$(awk -v n="$NODE_TARBALL" '$2==n {print $1}' "$shasums")
    [ -n "$expected" ] || { warn "No sha256 entry for $NODE_TARBALL in $shasums"; return 1; }
    actual=$(sha256sum "$tarball" | awk '{print $1}')
    if [ "$expected" = "$actual" ]; then
        return 0
    else
        warn "sha256 mismatch (expected $expected, got $actual)"
        return 1
    fi
}

download_node() {
    step 6 "Download Node.js v$NODE_VERSION tarball (cached, resumable)"
    local tarball="$CACHE_DIR/$NODE_TARBALL"
    local partial="$tarball.partial"
    local shasums="$CACHE_DIR/SHASUMS256.txt.v$NODE_VERSION"

    # Fetch SHASUMS256.txt if missing — cheap, small file
    if [ ! -s "$shasums" ]; then
        info "Fetching $NODE_SHASUMS_URL"
        curl -fL --max-time 60 -o "$shasums.partial" "$NODE_SHASUMS_URL" \
            || die "Failed to download SHASUMS256.txt"
        mv "$shasums.partial" "$shasums"
    fi

    if [ -f "$tarball" ] && verify_node_sha "$tarball" "$shasums"; then
        skip "Node tarball already cached and verified ($tarball)"
        return
    fi

    # Termux curl 8.20.0 has a bug: `curl --continue-at - -o file URL` silently
    # writes 0 bytes when the file already exists. Drive resume manually via an
    # explicit byte range and >> append. See install.sh history for details.
    local start=0
    if [ -f "$partial" ]; then
        start=$(stat -c %s "$partial")
        info "Resuming partial download from byte $start"
    elif [ -f "$tarball" ]; then
        # Existing tarball with bad sha — treat its bytes as a partial.
        mv "$tarball" "$partial"
        start=$(stat -c %s "$partial")
        info "Existing tarball failed sha check; resuming from byte $start"
    else
        info "Downloading $NODE_URL fresh"
    fi

    if [ "$start" -gt 0 ]; then
        curl -fL --max-time 900 -r "${start}-" "$NODE_URL" >> "$partial" \
            || die "curl failed during resume"
    else
        curl -fL --max-time 900 -o "$partial" "$NODE_URL" \
            || die "curl failed downloading $NODE_URL"
    fi

    if verify_node_sha "$partial" "$shasums"; then
        mv "$partial" "$tarball"
        ok "Tarball verified ($(du -h "$tarball" | awk '{print $1}'))"
    else
        # Sha didn't match — leave the .partial so a re-run keeps trying, but
        # die so the user notices.
        die "Tarball sha256 mismatch after download. The .partial is preserved for the next run."
    fi
}

# ── Step 7: Extract Node ───────────────────────────────────────────────────

extract_node() {
    step 7 "Extract Node.js"
    # node.real is a glibc ELF — we can't run it without ld.so just to check
    # the version. Use a marker file pinned to the version string instead.
    local marker="$STATE_DIR/node-extracted.v$NODE_VERSION"
    if [ -f "$marker" ] && [ -f "$NODE_DIR/bin/node.real" ] \
        && [ -f "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js" ]; then
        skip "Node v$NODE_VERSION already extracted ($NODE_DIR)"
        return
    fi

    rm -rf "$NODE_DIR" "$STATE_DIR/node-extracted".v*
    mkdir -p "$NODE_DIR"
    tar -xJf "$CACHE_DIR/$NODE_TARBALL" -C "$NODE_DIR" --strip-components=1
    [ -f "$NODE_DIR/bin/node" ] || die "Extraction did not produce $NODE_DIR/bin/node"

    # Rename node → node.real so the wrapper at bin/node can take its name.
    if [ -f "$NODE_DIR/bin/node" ] && [ ! -L "$NODE_DIR/bin/node" ]; then
        mv "$NODE_DIR/bin/node" "$NODE_DIR/bin/node.real"
    fi
    touch "$marker"
    ok "Node extracted to $NODE_DIR (node.real renamed)"
}

# ── Step 8: Copy glibc-compat.js patch from the cloned repo ────────────────

copy_glibc_compat() {
    step 8 "Copy glibc-compat.js from cloned upstream repo"
    local src="$REPO_DIR/patches/glibc-compat.js"
    local dst="$PATCH_DIR/glibc-compat.js"
    [ -s "$src" ] || die "Upstream glibc-compat.js missing or empty: $src"
    cp -f "$src" "$dst"
    [ -s "$dst" ] || die "Copy produced empty file: $dst"
    ok "glibc-compat.js copied ($(wc -l < "$dst") lines)"
}

# ── Step 9: Write the four wrappers in bin/ ────────────────────────────────

# Chmod a freshly-written temp wrapper and atomically swap it into place at
# $2. `mv` within the same directory is a rename(2): the live path always
# shows either the old wrapper or the fully-written new one, never a
# truncated in-between state (e.g. if this script is killed mid-write).
_finish_wrapper() {
    chmod 755 "$1"
    mv -f "$1" "$2"
}

# Inject the dns-doh shim block into a just-generated (not-yet-live) wrapper
# temp file, in place, when dohshim.so is present. Baking it in here — rather
# than relying on the recurring migrations to re-patch afterward — means a
# regenerated wrapper is never observably unpatched, even momentarily.
_apply_doh_shim() {
    local tmp="$1" label="$2"
    [ -f "$SHIM_SO" ] || return 0
    local patched; patched="$(mktemp "$BIN_DIR/.dohtmp.XXXXXX")"
    dns_doh_insert_block "$SHIM_SO" < "$tmp" > "$patched"
    if ! grep -qF "$DOH_MARKER_START" "$patched"; then
        rm -f "$patched"
        die "dns-doh block failed to insert into $label wrapper (anchor line missing) — refusing to write an inconsistent wrapper."
    fi
    mv -f "$patched" "$tmp"
}

write_wrappers() {
    step 9 "Write bin/node, bin/npm, bin/npx, bin/claude wrappers"
    local sh="$PREFIX/bin/bash"
    local compat="$PATCH_DIR/glibc-compat.js"

    # bin/node — the load-bearing wrapper. Absolute paths throughout.
    local tmp_node; tmp_node="$(mktemp "$BIN_DIR/.node.XXXXXX")"
    cat > "$tmp_node" <<NODE_WRAPPER
#!$sh
# Auto-generated by claude-code-android/install.sh — do not edit by hand.
# Force glibc resolver to use TCP for DNS (glibc-runner ignores resolv.conf options).
export RES_OPTIONS="\${RES_OPTIONS:-use-vc}"

# bionic libtermux-exec.so must not be loaded into the glibc process.
unset LD_PRELOAD

# Let glibc-compat.js patch process.execPath back to this wrapper.
export _OA_WRAPPER_PATH="$BIN_DIR/node"

# Auto-require the Android-quirks shim (idempotent).
_COMPAT="$compat"
if [ -f "\$_COMPAT" ]; then
    case "\${NODE_OPTIONS:-}" in
        *"\$_COMPAT"*) ;;
        *) export NODE_OPTIONS="\${NODE_OPTIONS:+\$NODE_OPTIONS }-r \$_COMPAT" ;;
    esac
fi

# Hoist leading --flags (before the first non-flag arg) into NODE_OPTIONS so
# ld.so doesn't consume them. Matches upstream's behavior.
_LEADING_OPTS=""
_COUNT=0
for _arg in "\$@"; do
    case "\$_arg" in --*) _COUNT=\$((_COUNT + 1)) ;; *) break ;; esac
done
if [ \$_COUNT -gt 0 ] && [ \$_COUNT -lt \$# ]; then
    while [ \$# -gt 0 ]; do
        case "\$1" in
            --check|--eval|--print|--interactive|--input-type|--test)
                break ;;   # not allowed in NODE_OPTIONS — leave in \$@ for node.real
            --*) _LEADING_OPTS="\${_LEADING_OPTS:+\$_LEADING_OPTS }\$1"; shift ;;
            *) break ;;
        esac
    done
    export NODE_OPTIONS="\${NODE_OPTIONS:+\$NODE_OPTIONS }\$_LEADING_OPTS"
fi

exec "$GLIBC_LDSO" --library-path "$GLIBC_LIBDIR" "$NODE_DIR/bin/node.real" "\$@"
NODE_WRAPPER
    _apply_doh_shim "$tmp_node" "node"
    _finish_wrapper "$tmp_node" "$BIN_DIR/node"

    local tmp_npm; tmp_npm="$(mktemp "$BIN_DIR/.npm.XXXXXX")"
    cat > "$tmp_npm" <<NPM_WRAPPER
#!$sh
exec "$BIN_DIR/node" "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js" "\$@"
NPM_WRAPPER
    _finish_wrapper "$tmp_npm" "$BIN_DIR/npm"

    local tmp_npx; tmp_npx="$(mktemp "$BIN_DIR/.npx.XXXXXX")"
    cat > "$tmp_npx" <<NPX_WRAPPER
#!$sh
exec "$BIN_DIR/node" "$NODE_DIR/lib/node_modules/npm/bin/npx-cli.js" "\$@"
NPX_WRAPPER
    _finish_wrapper "$tmp_npx" "$BIN_DIR/npx"

    local tmp_claude; tmp_claude="$(mktemp "$BIN_DIR/.claude.XXXXXX")"
    cat > "$tmp_claude" <<CLAUDE_WRAPPER
#!$sh
# Direct ld.so wrapper for Claude Code (no Node/npx hop).
export RES_OPTIONS="\${RES_OPTIONS:-use-vc}"

# bionic libtermux-exec.so must not be loaded into the glibc process.
unset LD_PRELOAD

exec "$GLIBC_LDSO" --library-path "$GLIBC_LIBDIR" \\
    "$NPM_PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" \\
    "\$@"
CLAUDE_WRAPPER
    _apply_doh_shim "$tmp_claude" "claude"
    _finish_wrapper "$tmp_claude" "$BIN_DIR/claude"

    # bin/claude-mux — target of dohshim's CLAUDE_CODE_EXECPATH rewrite. Claude
    # Code's Bash-tool grep/find functions exec it as ugrep/bfs; it re-execs
    # claude.exe via ld.so with argv[0] set so the bundled ripgrep/bfs run. No
    # dns-doh block (ripgrep/bfs need no DNS). Emitter shared via lib.sh.
    local tmp_mux; tmp_mux="$(mktemp "$BIN_DIR/.claude-mux.XXXXXX")"
    claude_mux_wrapper "$sh" "$GLIBC_LDSO" "$GLIBC_LIBDIR" \
        "$NPM_PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" \
        > "$tmp_mux"
    _finish_wrapper "$tmp_mux" "$BIN_DIR/claude-mux"

    ok "Wrote bin/{node,npm,npx,claude,claude-mux}"
}

# ── Step 10: Install Claude Code into the custom npm prefix ────────────────

is_elf() {
    # Read first 4 bytes; ELF magic is 0x7F 'E' 'L' 'F'.
    [ -f "$1" ] || return 1
    local magic
    magic=$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' ')
    [ "$magic" = "177ELF" ]
}

install_claude() {
    step 10 "Install Claude Code into custom npm prefix"
    local claude_exe="$NPM_PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
    if is_elf "$claude_exe"; then
        skip "Claude Code already installed ($claude_exe)"
        return
    fi
    # When this installer is run from a shell that's itself a child of npm/npx
    # (e.g. invoked from within Claude Code), the env carries a full set of
    # npm_config_* vars including npm_config_prefix and npm_config_offline.
    # Those override NPM_CONFIG_PREFIX and would drop the install in $PREFIX.
    # Scrub them and force --prefix on the CLI (highest priority in npm).
    info "Running npm install -g (clean env, explicit --prefix)"
    env -i \
        HOME="$HOME" \
        PREFIX="$PREFIX" \
        PATH="$BIN_DIR:$PREFIX/bin" \
        TMPDIR="$PREFIX/tmp" \
        TERM="${TERM:-xterm}" \
        NPM_CONFIG_PREFIX="$NPM_PREFIX" \
        NPM_CONFIG_REGISTRY="https://registry.npmjs.org/" \
        "$BIN_DIR/npm" install -g "$CLAUDE_PKG" --prefix="$NPM_PREFIX" \
        || die "npm install failed"
    is_elf "$claude_exe" || die "Post-install: claude.exe missing or not an ELF at $claude_exe"
    ok "Claude Code installed"
}

# ── Step 11: Smoke test in a clean shell (no inherited bashrc) ─────────────

smoke_test() {
    step 11 "Smoke test: run 'claude -v' in a clean shell"
    local out exit_code
    set +e
    out=$(env -i \
        HOME="$HOME" \
        PREFIX="$PREFIX" \
        TMPDIR="$PREFIX/tmp" \
        TERM="${TERM:-xterm}" \
        PATH="$PREFIX/bin:$PREFIX/glibc/bin" \
        "$PREFIX/bin/bash" --noprofile --norc -c "exec '$BIN_DIR/claude' -v" 2>&1)
    exit_code=$?
    set -e

    info "Output: $out"
    info "Exit code: $exit_code"

    if [ "$exit_code" -ne 0 ]; then
        die "Smoke test failed (exit $exit_code). NOT modifying .bashrc."
    fi
    if ! echo "$out" | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'; then
        die "Smoke test output did not contain a version string. NOT modifying .bashrc."
    fi
    printf '%s\n' "$out" > "$STATE_DIR/claude-tested"
    ok "Smoke test passed"
}

# ── Step 12: Append PATH-only block to ~/.bashrc (gated on test success) ──

append_bashrc() {
    step 12 "Append PATH-only block to ~/.bashrc"
    local rc="$HOME/.bashrc"
    [ -f "$rc" ] || touch "$rc"
    if grep -qF "$BASHRC_MARK_START" "$rc"; then
        skip "Block already present in $rc"
        return
    fi
    {
        printf '\n%s\n' "$BASHRC_MARK_START"
        printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
        printf '%s\n' "$BASHRC_MARK_END"
    } >> "$rc"
    ok "Appended PATH block to $rc"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    printf '%s%s== claude-code-android installer ==%s\n' "$C_BLD" "$C_BLU" "$C_NC"
    printf '   target: %s\n' "$INSTALL_DIR"

    preflight
    install_pkgs
    clone_repo
    validate_upstream
    install_glibc
    download_node
    extract_node
    copy_glibc_compat
    write_wrappers
    install_claude
    smoke_test
    append_bashrc

    printf '\n%s%sAll done.%s  Run: %ssource ~/.bashrc && claude -v%s\n' \
        "$C_BLD" "$C_GRN" "$C_NC" "$C_BLD" "$C_NC"
}

main "$@"

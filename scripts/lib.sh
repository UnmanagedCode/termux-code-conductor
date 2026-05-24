#!/data/data/com.termux/files/usr/bin/bash
# Shared helpers for bootstrap scripts.
# Source this file: source "$(dirname "$0")/lib.sh"

set -euo pipefail

if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m'; C_NC=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_NC=''
fi

log()  { printf '%s[bootstrap]%s %s\n' "$C_BLU" "$C_NC" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_NC" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_NC" "$*" >&2; }
die()  { printf '%s[err]%s %s\n' "$C_RED" "$C_NC" "$*" >&2; exit 1; }

require_termux() {
    [ "${PREFIX:-}" = "/data/data/com.termux/files/usr" ] \
        || die "Not running inside Termux (PREFIX=$PREFIX). Install Termux from F-Droid first."
    [ "$(uname -m)" = "aarch64" ] \
        || die "Unsupported arch $(uname -m). Only aarch64 Android is supported."
}

# ── Workspace CLAUDE.md sync ────────────────────────────────────────────────
# Reconciles the vendored cc-projects-CLAUDE.md with ~/cc-projects/CLAUDE.md.
# We keep a "baseline" of what we last wrote, under ~/.cache/code-conductor-
# bootstrap/, so we can tell user edits apart from vendor changes.
#
# Cases:
#   target == vendor            → up to date, bump baseline, no-op
#   target == baseline          → user untouched, vendor changed → silent update
#   target != baseline, baseline == vendor → user edited, vendor unchanged → keep
#   target != baseline, baseline != vendor → both changed → prompt (TTY) or keep (no TTY)
#
# Args: $1 = vendor file (in this repo), $2 = target (where it lives on disk)
sync_workspace_claudemd() {
    local vendor="$1" target="$2"
    local state_dir="$HOME/.cache/code-conductor-bootstrap"
    local baseline="$state_dir/CLAUDE.md.installed"

    [ -f "$vendor" ] || return 0
    [ -f "$target" ] || return 0  # nothing to sync; install-cc.sh handles first-create

    mkdir -p "$state_dir"
    if [ ! -f "$baseline" ]; then
        # No baseline recorded yet (older install). Seed it from the vendor;
        # if the user has already diverged, we'll catch it on the next update.
        cp "$vendor" "$baseline"
    fi

    local h_target h_baseline h_vendor
    h_target=$(sha256sum "$target" | awk '{print $1}')
    h_baseline=$(sha256sum "$baseline" | awk '{print $1}')
    h_vendor=$(sha256sum "$vendor" | awk '{print $1}')

    if [ "$h_target" = "$h_vendor" ]; then
        cp "$vendor" "$baseline"
        return 0
    fi

    if [ "$h_target" = "$h_baseline" ]; then
        log "Updating $target with new workspace conventions from upstream"
        cp "$vendor" "$target"
        cp "$vendor" "$baseline"
        return 0
    fi

    if [ "$h_baseline" = "$h_vendor" ]; then
        # User edited; vendor hasn't moved since their baseline. Leave alone.
        return 0
    fi

    # Three-way: user edited AND vendor moved.
    warn "Workspace CLAUDE.md conflict:"
    warn "  $target has been edited by you"
    warn "  AND a new upstream version is available"

    # Check /dev/tty is actually openable (a controlling terminal exists),
    # not just that the device node is readable.
    if ! ( : </dev/tty ) 2>/dev/null; then
        warn "No TTY available — keeping your version. New upstream is at:"
        warn "  $vendor"
        return 0
    fi

    while true; do
        {
            printf '\n%s[?]%s How to resolve?\n' "$C_YEL" "$C_NC"
            printf '  [k] keep your version (default; new upstream becomes the next baseline)\n'
            printf '  [o] overwrite with new upstream (your file is backed up first)\n'
            printf '  [d] diff yours vs upstream, then re-ask\n'
            printf 'Choice [k/o/d]: '
        } >/dev/tty
        local ans=""
        read -r ans </dev/tty || ans=""
        case "$ans" in
            o|O)
                local backup="${target}.bak-$(date +%Y%m%d-%H%M%S)"
                cp "$target" "$backup"
                cp "$vendor" "$target"
                cp "$vendor" "$baseline"
                ok "Installed new upstream version. Your previous file is at $backup"
                return 0
                ;;
            d|D)
                diff -u "$target" "$vendor" >/dev/tty || true
                ;;
            ''|k|K)
                cp "$vendor" "$baseline"
                log "Kept your version at $target (won't ask again until upstream changes)"
                return 0
                ;;
            *)
                printf '  (unknown choice: %s)\n' "$ans" >/dev/tty
                ;;
        esac
    done
}

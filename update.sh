#!/data/data/com.termux/files/usr/bin/bash
# Update the bootstrap repo, Code Conductor, and (if installed) the
# Playwright harness, then re-apply only the work that's actually needed.
#
# Usage:
#   ./update.sh           pull latest + re-run idempotent bootstrap steps
#   ./update.sh --cli     same + force-upgrade Claude CLI to latest npm release
#   ./update.sh --no-restart   skip restarting the CC server even if it changed

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO/scripts/lib.sh"

UPGRADE_CLI=0
RESTART=1
for arg in "$@"; do
    case "$arg" in
        --cli) UPGRADE_CLI=1 ;;
        --no-restart) RESTART=0 ;;
        -h|--help)
            sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "Unknown flag: $arg" ;;
    esac
done

require_termux

CC_PROJECTS_DIR="$HOME/cc-projects"
CC_DIR="$CC_PROJECTS_DIR/code-conductor"
NPM="$HOME/claude-code-android/bin/npm"

# ── 1. Update the bootstrap repo ─────────────────────────────────────────────
[ -d "$REPO/.git" ] || die "$REPO is not a git checkout. Re-clone the repo instead."

log "Updating bootstrap repo"
( cd "$REPO" && git fetch --quiet )
BOOT_OLD="$(cd "$REPO" && git rev-parse HEAD)"
( cd "$REPO" && git pull --ff-only --quiet )
BOOT_NEW="$(cd "$REPO" && git rev-parse HEAD)"
if [ "$BOOT_OLD" = "$BOOT_NEW" ]; then
    log "  bootstrap already up to date at $(git -C "$REPO" rev-parse --short HEAD)"
    INSTALLER_CHANGED=0
else
    ok "  bootstrap $(git -C "$REPO" rev-parse --short "$BOOT_OLD") → $(git -C "$REPO" rev-parse --short "$BOOT_NEW")"
    git -C "$REPO" diff --name-only "$BOOT_OLD" "$BOOT_NEW" | sed 's/^/    /'
    if git -C "$REPO" diff --name-only "$BOOT_OLD" "$BOOT_NEW" | grep -q '^scripts/vendor/claude-install.sh$'; then
        INSTALLER_CHANGED=1
    else
        INSTALLER_CHANGED=0
    fi
fi

# ── 2. Update Code Conductor ─────────────────────────────────────────────────
CC_CHANGED=0
CC_PKG_CHANGED=0
if [ -d "$CC_DIR/.git" ]; then
    log "Updating Code Conductor"
    ( cd "$CC_DIR" && git fetch --quiet )
    CC_OLD="$(cd "$CC_DIR" && git rev-parse HEAD)"
    ( cd "$CC_DIR" && git pull --ff-only --quiet )
    CC_NEW="$(cd "$CC_DIR" && git rev-parse HEAD)"
    if [ "$CC_OLD" = "$CC_NEW" ]; then
        log "  Code Conductor already up to date at $(git -C "$CC_DIR" rev-parse --short HEAD)"
    else
        ok "  Code Conductor $(git -C "$CC_DIR" rev-parse --short "$CC_OLD") → $(git -C "$CC_DIR" rev-parse --short "$CC_NEW")"
        CC_CHANGED=1
        if git -C "$CC_DIR" diff --name-only "$CC_OLD" "$CC_NEW" | grep -qE '^(package\.json|package-lock\.json)$'; then
            CC_PKG_CHANGED=1
        fi
    fi
else
    warn "Code Conductor not installed yet — run ./bootstrap.sh to get it"
fi

# ── 2b. Update installed optional projects (harness, code-share, …) ──────────
# Loop over the optional-project registry (lib.sh) and update any that are
# actually cloned. Pull + reinstall deps when package.json/lockfile changed.
for opt in $(optional_project_names); do
    opt_dir="$CC_PROJECTS_DIR/$opt"
    [ -d "$opt_dir/.git" ] || continue
    log "Updating $opt"
    ( cd "$opt_dir" && git fetch --quiet )
    O_OLD="$(cd "$opt_dir" && git rev-parse HEAD)"
    ( cd "$opt_dir" && git pull --ff-only --quiet )
    O_NEW="$(cd "$opt_dir" && git rev-parse HEAD)"
    if [ "$O_OLD" = "$O_NEW" ]; then
        log "  $opt already up to date at $(git -C "$opt_dir" rev-parse --short HEAD)"
    else
        ok "  $opt $(git -C "$opt_dir" rev-parse --short "$O_OLD") → $(git -C "$opt_dir" rev-parse --short "$O_NEW")"
        if [ -f "$opt_dir/package.json" ] \
            && git -C "$opt_dir" diff --name-only "$O_OLD" "$O_NEW" | grep -qE '^(package\.json|package-lock\.json)$'; then
            log "  $opt deps changed — running npm install"
            ( cd "$opt_dir" && "$NPM" install --no-audit --no-fund )
        fi
    fi
done

# ── 3. Re-apply ──────────────────────────────────────────────────────────────
# Reconcile the vendored workspace CLAUDE.md with the user's copy (silent
# update if untouched, prompt on three-way conflict).
sync_workspace_claudemd \
    "$REPO/scripts/vendor/cc-projects-CLAUDE.md" \
    "$CC_PROJECTS_DIR/CLAUDE.md"

bash "$REPO/scripts/register-alias.sh"

if [ "$UPGRADE_CLI" = "1" ]; then
    log "Force-upgrading Claude CLI to latest"
    "$NPM" install -g @anthropic-ai/claude-code@latest || die "Claude CLI upgrade failed"
    ok "Claude CLI now at $("$HOME/claude-code-android/bin/claude" -v)"
elif [ "$INSTALLER_CHANGED" = "1" ]; then
    warn "Vendored Claude installer changed — re-running install-claude-cli.sh"
    bash "$REPO/scripts/install-claude-cli.sh"
fi

if [ "$CC_PKG_CHANGED" = "1" ]; then
    log "Code Conductor deps changed — running npm install"
    ( cd "$CC_DIR" && "$NPM" install --no-audit --no-fund )
fi

if [ "$CC_CHANGED" = "1" ] && [ "$RESTART" = "1" ]; then
    if curl -sf "http://127.0.0.1:8787/" >/dev/null 2>&1; then
        log "Restarting Code Conductor server (code changed)"
        # Stop every node server.js process whose cwd is $CC_DIR (matches both
        # 'node server.js' from `npm start` and 'node /abs/.../server.js' from
        # the self-respawn path).
        for pid in $(pgrep -f 'node.*server\.js' 2>/dev/null); do
            cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
            [ "$cwd" = "$CC_DIR" ] && kill "$pid" 2>/dev/null || true
        done
        sleep 1
        ( cd "$CC_DIR" && PROJECTS_ROOT="$CC_PROJECTS_DIR" nohup "$NPM" start >server.log 2>&1 & )
        for i in $(seq 1 10); do
            sleep 1
            if curl -sf "http://127.0.0.1:8787/" >/dev/null 2>&1; then
                ok "Code Conductor restarted at http://127.0.0.1:8787"
                break
            fi
        done
    else
        log "Code Conductor code changed but server isn't running — start it with: cc start"
    fi
fi

ok "Update complete."

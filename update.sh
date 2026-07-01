#!/data/data/com.termux/files/usr/bin/bash
# Update the bootstrap repo, Code Conductor, and (if installed) the
# Playwright harness, then re-apply only the work that's actually needed.
#
# Usage:
#   ./update.sh           pull latest + re-run idempotent bootstrap steps
#   ./update.sh --cli     same + force-upgrade Claude CLI to latest npm release
#   ./update.sh --no-restart   skip restarting the CC server even if it changed
#
# When Code Conductor's code changed and the server is running, this triggers a
# GRACEFUL restart-and-resume via its POST /admin/restart endpoint: live turns
# drain to idle (up to 60s, never force-interrupted), the server relaunches
# itself, and sessions are resurrected with --resume. --no-restart skips it.

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
NPM_PREFIX="$HOME/claude-code-android/npm-prefix"

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
bash "$REPO/scripts/register-alias.sh"

if [ "$UPGRADE_CLI" = "1" ]; then
    log "Force-upgrading Claude CLI to latest"
    env -i \
        HOME="$HOME" \
        PREFIX="$PREFIX" \
        PATH="$(dirname "$NPM"):$PREFIX/bin" \
        TMPDIR="${TMPDIR:-$PREFIX/tmp}" \
        TERM="${TERM:-xterm}" \
        NPM_CONFIG_PREFIX="$NPM_PREFIX" \
        NPM_CONFIG_REGISTRY="https://registry.npmjs.org/" \
        "$NPM" install -g @anthropic-ai/claude-code@latest --prefix="$NPM_PREFIX" \
        || die "Claude CLI upgrade failed"
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
        log "Requesting graceful restart + resume of Code Conductor server (code changed)"
        # POST /admin/restart {"resume":true} → drainAndScheduleRestart: winds
        # live turns down to idle (60s grace, never force-interrupts), writes a
        # resume manifest, then relaunches the server ITSELF and resurrects the
        # sessions (--resume). The endpoint replies 202 immediately and the server
        # stays up through the (possibly long) drain, so we POST-and-report rather
        # than polling for a bounce we can't observe — resume self-heals.
        if curl -sf -X POST -H 'content-type: application/json' \
                -d '{"resume":true}' \
                "http://127.0.0.1:8787/admin/restart" >/dev/null 2>&1; then
            ok "Graceful restart requested — server will drain live turns (up to 60s), then relaunch and resume sessions."
        else
            warn "Restart request failed — check the server; restart manually with: cc start"
        fi
    else
        log "Code Conductor code changed but server isn't running — start it with: cc start"
    fi
fi

bash "$REPO/scripts/run-migrations.sh" || warn "migrations runner errored — continuing"

ok "Update complete."

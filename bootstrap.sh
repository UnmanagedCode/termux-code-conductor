#!/data/data/com.termux/files/usr/bin/bash
# termux-code-conductor: one-shot installer for Claude CLI + Code Conductor
# (CC) on Termux/Android (aarch64).
#
# Two ways to run:
#   curl -fsSL https://raw.githubusercontent.com/UnmanagedCode/termux-code-conductor/main/bootstrap.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/UnmanagedCode/termux-code-conductor/main/bootstrap.sh | bash -s -- --with-playwright
#   git clone https://github.com/UnmanagedCode/termux-code-conductor.git && cd termux-code-conductor && ./bootstrap.sh [flags]
#
# Flags:
#   --with-playwright    install termux-playwright-harness (skips prompt)
#   -y, --yes, --non-interactive
#                        accept defaults, never prompt. Default for harness is OFF.
#
# When no flag is given and a TTY is available, the script asks interactively.

set -euo pipefail

# ── Repo coordinates ────────────────────────────────────────────────────────
GITHUB_USER="UnmanagedCode"
REPO_NAME="termux-code-conductor"
CLONE_TARGET="$HOME/cc-projects/termux-code-conductor"

# ── Parse flags ─────────────────────────────────────────────────────────────
WITH_PLAYWRIGHT=""
NON_INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --with-playwright) WITH_PLAYWRIGHT=1 ;;
        -y|--yes|--non-interactive) NON_INTERACTIVE=1 ;;
        -h|--help)
            sed -n '3,14p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

# ── Self-bootstrap when piped via curl ──────────────────────────────────────
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
if [ "$SCRIPT_PATH" = "bash" ] || [ ! -f "$SCRIPT_PATH" ]; then
    PIPED=1
else
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    if [ -f "$SCRIPT_DIR/scripts/install-claude-cli.sh" ]; then
        PIPED=0
    else
        PIPED=1
    fi
fi

if [ "$PIPED" = "1" ]; then
    echo "[bootstrap] piped via curl — cloning repo to $CLONE_TARGET"
    if ! command -v git >/dev/null 2>&1; then
        echo "[bootstrap] git not found — bootstrapping Termux packages"
        echo "[bootstrap] (this triggers Termux's first-run mirror selection if it hasn't happened yet)"
        # `pkg update` first so the mirror is selected and package lists are
        # refreshed under a stable shell. Doing this BEFORE `pkg install`
        # avoids the case where the curl|bash process group gets killed
        # mid-mirror-test on a brand-new Termux install.
        pkg update -y </dev/null 2>&1 || true
        if ! pkg install -y git </dev/null; then
            cat >&2 <<EOM

[bootstrap] Failed to install git automatically. On a brand-new Termux
session the package manager sometimes needs a clean shell to finish
selecting a mirror. Please run these two commands manually, then re-run
the curl one-liner:

    pkg update -y
    pkg install -y git

EOM
            exit 1
        fi
    fi
    mkdir -p "$(dirname "$CLONE_TARGET")"
    if [ ! -d "$CLONE_TARGET/.git" ]; then
        git clone "https://github.com/${GITHUB_USER}/${REPO_NAME}.git" "$CLONE_TARGET"
    else
        echo "[bootstrap] $CLONE_TARGET already a clone — syncing to origin/main"
        ( cd "$CLONE_TARGET" && git fetch --quiet origin )
        if ! ( cd "$CLONE_TARGET" && git pull --ff-only --quiet ); then
            # Non-fast-forward (probably a force-push upstream, or local
            # generated divergence). This repo is a setup artifact, not
            # user work — refuse only if there are uncommitted changes
            # that would actually be lost.
            if ( cd "$CLONE_TARGET" && [ -z "$(git status --porcelain)" ] ); then
                echo "[bootstrap] local branch diverged from origin and has no uncommitted changes — hard-resetting to origin/main"
                ( cd "$CLONE_TARGET" && git reset --hard --quiet origin/main )
            else
                cat >&2 <<EOM
[bootstrap] $CLONE_TARGET has diverged from origin/main AND has uncommitted
changes. Refusing to clobber them. Resolve by hand:

    cd $CLONE_TARGET
    git status                       # inspect
    git stash || git commit -am wip  # save your work
    git fetch && git reset --hard origin/main

EOM
                exit 1
            fi
        fi
    fi
    exec "$CLONE_TARGET/bootstrap.sh" "$@"
fi

# ── In-repo execution ───────────────────────────────────────────────────────
REPO="$SCRIPT_DIR"
source "$REPO/scripts/lib.sh"

log "Code Conductor bootstrap starting from $REPO"
require_termux

# ── Resolve the Playwright choice ──────────────────────────────────────────
if [ -z "$WITH_PLAYWRIGHT" ]; then
    if [ "$NON_INTERACTIVE" = "1" ]; then
        WITH_PLAYWRIGHT=0
        log "Non-interactive — skipping Playwright harness (use --with-playwright to include it)"
    elif [ -r /dev/tty ]; then
        printf '\n%s[?]%s Also install the Playwright harness for visual UI debugging? [y/N] ' "$C_YEL" "$C_NC" >/dev/tty
        read -r ans </dev/tty || ans=""
        case "$ans" in
            [yY]|[yY][eE][sS]) WITH_PLAYWRIGHT=1 ;;
            *) WITH_PLAYWRIGHT=0 ;;
        esac
    else
        WITH_PLAYWRIGHT=0
        warn "No TTY available and no flag given — defaulting to no harness"
    fi
fi

# Mark the bootstrap repo itself as part of the CC-Dev group
# (only when it lives inside ~/cc-projects, i.e. after the self-bootstrap)
if [ "$REPO" = "$CLONE_TARGET" ]; then
    META_DIR="$REPO/.code-conductor"
    if [ ! -f "$META_DIR/project.json" ]; then
        mkdir -p "$META_DIR"
        printf '{\n  "group": "CC-Dev"\n}\n' > "$META_DIR/project.json"
        ok "Marked bootstrap repo as CC-Dev group"
    fi
fi

TOTAL=3
[ "$WITH_PLAYWRIGHT" = "1" ] && TOTAL=4

log "Step 1/$TOTAL — install Claude CLI"
bash "$REPO/scripts/install-claude-cli.sh"

log "Step 2/$TOTAL — clone + start Code Conductor"
bash "$REPO/scripts/install-cc.sh"

if [ "$WITH_PLAYWRIGHT" = "1" ]; then
    log "Step 3/$TOTAL — install termux-playwright-harness"
    bash "$REPO/scripts/install-playwright.sh"
    log "Step 4/$TOTAL — register shell aliases"
else
    log "Step 3/$TOTAL — register shell aliases"
fi
bash "$REPO/scripts/register-alias.sh"

PLAYWRIGHT_LINE=""
if [ "$WITH_PLAYWRIGHT" = "1" ]; then
    PLAYWRIGHT_LINE="  Playwright:     $HOME/cc-projects/termux-playwright-harness"
fi

cat <<EOF

${C_GRN}Done.${C_NC}

  CC UI:          http://127.0.0.1:8787
  Server logs:    $HOME/cc-projects/code-conductor/server.log
  Bootstrap:      $REPO
  Code Conductor: $HOME/cc-projects/code-conductor
  Projects root:  $HOME/cc-projects
$PLAYWRIGHT_LINE

Aliases + dispatcher registered in ~/.bashrc:
  cc start | stop | logs | update | projects     (tab-completes)
  cc-start, cc-stop, cc-logs, cc-update          (direct shortcuts)
  cc-projects                                    (cd into ~/cc-projects)

Run \`source ~/.bashrc\` (or open a new Termux session) to pick them up.
EOF

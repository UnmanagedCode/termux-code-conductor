#!/data/data/com.termux/files/usr/bin/bash
# Install (or update) one optional add-on project into ~/cc-projects: clone it,
# tag it as the CC-Dev group, and `npm install` its deps if it ships a
# package.json. The set of installable projects lives in lib.sh's registry
# (optional_projects_table). Idempotent — re-running just pulls + reinstalls.
#
# Usage:
#   install-optional.sh <name>     install/update the named optional project
#   install-optional.sh            list available optional projects + status

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

require_termux

CC_PROJECTS_DIR="$HOME/cc-projects"

# ── No argument (or -h): list what's available ───────────────────────────────
NAME="${1:-}"
if [ -z "$NAME" ] || [ "$NAME" = "-h" ] || [ "$NAME" = "--help" ]; then
    echo "Optional projects (install with: cc install <name>)"
    echo
    optional_projects_table | while IFS=$'\t' read -r name url desc; do
        if [ -d "$CC_PROJECTS_DIR/$name/.git" ]; then
            mark="${C_GRN}[installed]${C_NC}"
        else
            mark="           "
        fi
        printf '  %b %-26s %s\n' "$mark" "$name" "$desc"
    done
    exit 0
fi

# ── Resolve name/alias → canonical name + URL ────────────────────────────────
CANON="$(canonical_optional_project "$NAME")" \
    || die "Unknown optional project '$NAME'. Run 'cc install' to list available ones."

# The Playwright harness needs the Termux chromium package, so it has its own
# installer with that extra setup. Everything else uses the generic path below.
if [ "$CANON" = "termux-playwright-harness" ]; then
    exec bash "$HERE/install-playwright.sh"
fi

URL="$(optional_project_url "$CANON")" || die "No git URL registered for '$CANON'"
DIR="$CC_PROJECTS_DIR/$CANON"

mkdir -p "$CC_PROJECTS_DIR"

# ── Clone or fast-forward ────────────────────────────────────────────────────
if [ -d "$DIR/.git" ]; then
    log "$CANON clone exists — fetching latest"
    ( cd "$DIR" && git fetch --quiet && git pull --ff-only --quiet )
    ok "$CANON at $(git -C "$DIR" rev-parse --short HEAD)"
elif [ -e "$DIR" ]; then
    die "$DIR exists but is not a git checkout. Move or remove it, then re-run."
else
    log "Cloning $URL → $DIR"
    git clone --quiet "$URL" "$DIR"
    ok "Cloned at $(git -C "$DIR" rev-parse --short HEAD)"
fi

# ── Tag it as the CC-Dev group in Code Conductor's central store ─────────────
META_DIR="$CC_PROJECTS_DIR/.code-conductor/projects/$CANON"
mkdir -p "$META_DIR"
printf '{\n  "group": "CC-Dev"\n}\n' > "$META_DIR/project.json"
ok "Marked $CANON as CC-Dev group"

# ── Install deps if there's a package.json ───────────────────────────────────
if [ -f "$DIR/package.json" ]; then
    if ! command -v npm >/dev/null 2>&1; then
        if [ -d "$HOME/claude-code-android/bin" ]; then
            export PATH="$HOME/claude-code-android/bin:$PATH"
        fi
    fi
    command -v npm >/dev/null 2>&1 || die "npm not on PATH. Did the Claude CLI install step finish?"
    log "Installing $CANON deps (npm install)"
    ( cd "$DIR" && npm install --no-audit --no-fund )
fi

# ── Project-specific system deps ─────────────────────────────────────────────
if [ "$CANON" = "code-share" ]; then
    if ! command -v cloudflared >/dev/null 2>&1; then
        log "Installing cloudflared (tunnel dependency for code-share)"
        pkg install -y cloudflared </dev/null
    fi
    ok "cloudflared at $(command -v cloudflared)"
fi

ok "$CANON ready at $DIR"

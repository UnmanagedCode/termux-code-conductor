#!/data/data/com.termux/files/usr/bin/bash
# termux-code-conductor: one-shot installer for Claude CLI + Code Conductor
# (CC) on Termux/Android (aarch64).
#
# Two ways to run:
#   curl -fsSL https://raw.githubusercontent.com/UnmanagedCode/termux-code-conductor/main/bootstrap.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/UnmanagedCode/termux-code-conductor/main/bootstrap.sh | bash -s -- --with=code-share,playwright
#   git clone https://github.com/UnmanagedCode/termux-code-conductor.git && cd termux-code-conductor && ./bootstrap.sh [flags]
#
# Flags:
#   --with=<name,...>    install these optional projects (comma-separated;
#                        repeatable). Skips the interactive prompt. Names come
#                        from the registry in scripts/lib.sh, e.g. code-share,
#                        playwright (alias for termux-playwright-harness).
#   -y, --yes, --non-interactive
#                        accept defaults, never prompt. Installs NO optional
#                        projects unless --with= is also given.
#
# With no --with= flag and a TTY available, the script asks [y/N] per optional
# project.

set -euo pipefail

# ── Repo coordinates ────────────────────────────────────────────────────────
GITHUB_USER="UnmanagedCode"
REPO_NAME="termux-code-conductor"
CLONE_TARGET="$HOME/cc-projects/termux-code-conductor"

# ── Parse flags ─────────────────────────────────────────────────────────────
# Optional-project names can't be validated yet (lib.sh is sourced only after
# the self-bootstrap re-exec below), so just accumulate the raw --with= values.
WITH_GIVEN=0
WITH_RAW=""
NON_INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --with=*) WITH_GIVEN=1; WITH_RAW="$WITH_RAW,${arg#--with=}" ;;
        -y|--yes|--non-interactive) NON_INTERACTIVE=1 ;;
        -h|--help)
            sed -n '3,20p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'
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

# ── Resolve which optional projects to install ──────────────────────────────
# Build SELECTED[] of canonical names: from --with= when given, else one [y/N]
# prompt per registry project when interactive, else none.
SELECTED=()
select_optional() {            # add a canonical name (deduped) to SELECTED[]
    local canon i
    canon="$(canonical_optional_project "$1")" \
        || die "Unknown optional project '$1'. Known: $(optional_project_names | tr '\n' ' ')"
    if [ "${#SELECTED[@]}" -gt 0 ]; then
        for i in "${SELECTED[@]}"; do [ "$i" = "$canon" ] && return 0; done
    fi
    SELECTED+=("$canon")
}

if [ "$WITH_GIVEN" = "1" ]; then
    IFS=',' read -ra _with_items <<< "$WITH_RAW"
    for item in "${_with_items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"   # trim leading whitespace
        item="${item%"${item##*[![:space:]]}"}"   # trim trailing whitespace
        [ -z "$item" ] && continue
        select_optional "$item"
    done
elif [ "$NON_INTERACTIVE" = "1" ]; then
    log "Non-interactive — installing no optional projects (use --with=<name,...>)"
elif ( : </dev/tty ) 2>/dev/null; then
    while IFS=$'\t' read -r _name _url _desc; do
        printf '\n%s[?]%s Also install %s — %s? [y/N] ' \
            "$C_YEL" "$C_NC" "$_name" "$_desc" >/dev/tty
        read -r ans </dev/tty || ans=""
        case "$ans" in [yY]|[yY][eE][sS]) select_optional "$_name" ;; esac
    done < <(optional_projects_table)
else
    warn "No TTY available and no --with= flag — installing no optional projects"
fi

# Mark the bootstrap repo itself as part of the CC-Dev group
# (only when it lives inside ~/cc-projects, i.e. after the self-bootstrap).
# Group metadata lives in Code Conductor's central store at
# <cc-projects>/.code-conductor/projects/<name>/project.json — not inside
# the project dir, so the repo's own tree stays clean.
if [ "$REPO" = "$CLONE_TARGET" ]; then
    META_DIR="$HOME/cc-projects/.code-conductor/projects/$REPO_NAME"
    if [ ! -f "$META_DIR/project.json" ]; then
        mkdir -p "$META_DIR"
        printf '{\n  "group": "CC-Dev"\n}\n' > "$META_DIR/project.json"
        ok "Marked bootstrap repo as CC-Dev group"
    fi
fi

N_OPT="${#SELECTED[@]}"
# Steps: 1 Claude CLI, 2 Code Conductor, then one per optional project, then aliases.
TOTAL=$((3 + N_OPT))

log "Step 1/$TOTAL — install Claude CLI"
bash "$REPO/scripts/install-claude-cli.sh"

log "Step 2/$TOTAL — clone + start Code Conductor"
bash "$REPO/scripts/install-cc.sh"

step=3
if [ "$N_OPT" -gt 0 ]; then
    for opt in "${SELECTED[@]}"; do
        log "Step $step/$TOTAL — install optional project: $opt"
        bash "$REPO/scripts/install-optional.sh" "$opt"
        step=$((step + 1))
    done
fi

log "Step $step/$TOTAL — register shell aliases"
bash "$REPO/scripts/register-alias.sh"

OPT_BLOCK=""
if [ "$N_OPT" -gt 0 ]; then
    for opt in "${SELECTED[@]}"; do
        OPT_BLOCK="${OPT_BLOCK}  Optional:       $HOME/cc-projects/$opt"$'\n'
    done
fi

cat <<EOF

${C_GRN}Done.${C_NC}

  CC UI:          http://127.0.0.1:8787
  Server logs:    $HOME/cc-projects/code-conductor/server.log
  Bootstrap:      $REPO
  Code Conductor: $HOME/cc-projects/code-conductor
  Projects root:  $HOME/cc-projects
${OPT_BLOCK}
Aliases + dispatcher registered in ~/.bashrc:
  cc start|stop|logs|update|upgrade|install|projects   (tab-completes)
  cc-start, cc-stop, cc-logs, cc-update, cc-upgrade    (direct shortcuts)
  cc-install <name>                                    (install an optional project; no arg lists them)
  cc-projects                                          (cd into ~/cc-projects)

Run \`source ~/.bashrc\` (or open a new Termux session) to pick them up.
EOF

CC_LOCAL_URL="http://127.0.0.1:8787"
if [ "$NON_INTERACTIVE" != "1" ] && ( : </dev/tty ) 2>/dev/null; then
    printf '\n%s[?]%s Open the Code Conductor UI in your browser now? [y/N] ' \
        "$C_YEL" "$C_NC" >/dev/tty
    read -r ans </dev/tty || ans=""
    case "$ans" in
        [yY]|[yY][eE][sS])
            if command -v termux-open-url >/dev/null 2>&1; then
                termux-open-url "$CC_LOCAL_URL" \
                    || warn "termux-open-url failed — open $CC_LOCAL_URL manually."
            elif command -v am >/dev/null 2>&1; then
                am start -a android.intent.action.VIEW -d "$CC_LOCAL_URL" \
                        >/dev/null 2>&1 \
                    || warn "Couldn't auto-launch browser. Open $CC_LOCAL_URL manually."
            else
                warn "No URL opener available. Open $CC_LOCAL_URL manually."
            fi
            ;;
    esac
fi

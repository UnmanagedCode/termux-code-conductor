#!/data/data/com.termux/files/usr/bin/bash
# Append a managed block to ~/.bashrc that registers the `cc` dispatcher
# function (with bash completion) plus the cc-* shortcut aliases.
# Idempotent: removes any prior block and rewrites it.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

BASHRC="$HOME/.bashrc"
MARK_START="# >>> code-conductor aliases >>>"
MARK_END="# <<< code-conductor aliases <<<"
REPO="$(cd "$HERE/.." && pwd)"
CC_PROJECTS_DIR="$HOME/cc-projects"
CC_DIR="$CC_PROJECTS_DIR/code-conductor"
CC_LOCAL_URL="http://127.0.0.1:8787"

# Space-separated optional-project names, baked into the completion below so it
# can suggest targets for `cc install <name>`. Sourced from lib.sh's registry.
OPTIONAL_NAMES="$(optional_project_names | tr '\n' ' ')"

touch "$BASHRC"

# Strip any previous managed block so we can rewrite cleanly
if grep -qF "$MARK_START" "$BASHRC"; then
    awk -v s="$MARK_START" -v e="$MARK_END" '
        $0 == s {skip=1; next}
        $0 == e {skip=0; next}
        !skip {print}
    ' "$BASHRC" > "$BASHRC.tmp" && mv "$BASHRC.tmp" "$BASHRC"
fi

cat >> "$BASHRC" <<EOF
$MARK_START
# Code Conductor — multi-agent orch app
# Subcommand form:   cc start|stop|logs|update|upgrade|install|projects
# Shortcut aliases:  cc-start, cc-stop, cc-logs, cc-update, cc-upgrade, cc-install, cc-projects
cc-start() {
    ( cd "$CC_DIR" && PROJECTS_ROOT="$CC_PROJECTS_DIR" nohup npm start >server.log 2>&1 & ) \\
        && echo "Code Conductor starting at $CC_LOCAL_URL (logs: $CC_DIR/server.log)"
}
cc-stop() {
    # Kill every node server.js process whose cwd is $CC_DIR. This catches
    # both 'node server.js' (started via npm start) and 'node /abs/.../server.js'
    # (started via the in-process self-respawn).
    local pid cwd pids=""
    for pid in \$(pgrep -f 'node.*server\\.js' 2>/dev/null); do
        cwd=\$(readlink "/proc/\$pid/cwd" 2>/dev/null) || continue
        [ "\$cwd" = "$CC_DIR" ] && pids="\$pids \$pid"
    done
    if [ -n "\$pids" ]; then
        kill \$pids 2>/dev/null
        echo "Code Conductor stopped"
    else
        echo "no Code Conductor process running"
    fi
}
cc-logs() { tail -f "$CC_DIR/server.log"; }
cc-update() { bash "$REPO/update.sh" "\$@"; }
cc-upgrade() { bash "$REPO/update.sh" --cli "\$@"; }
cc-install() { bash "$REPO/scripts/install-optional.sh" "\$@"; }
cc-projects() { cd "$CC_PROJECTS_DIR"; }

# Unified dispatcher
cc() {
    local sub="\${1:-}"
    shift || true
    case "\$sub" in
        start)    cc-start "\$@" ;;
        stop)     cc-stop "\$@" ;;
        logs)     cc-logs "\$@" ;;
        update)   cc-update "\$@" ;;
        upgrade)  cc-upgrade "\$@" ;;
        install)  cc-install "\$@" ;;
        projects) cc-projects "\$@" ;;
        ''|-h|--help)
            echo "Usage: cc {start|stop|logs|update|upgrade|install|projects}"
            ;;
        *)
            echo "cc: unknown subcommand '\$sub'" >&2
            echo "Usage: cc {start|stop|logs|update|upgrade|install|projects}" >&2
            return 2
            ;;
    esac
}

# Bash completion: first-arg subcommands, plus optional-project names for
# 'cc install <name>'.
_cc_complete() {
    local cur="\${COMP_WORDS[COMP_CWORD]}"
    if [ "\$COMP_CWORD" = "1" ]; then
        COMPREPLY=( \$(compgen -W "start stop logs update upgrade install projects" -- "\$cur") )
    elif [ "\$COMP_CWORD" = "2" ] && [ "\${COMP_WORDS[1]}" = "install" ]; then
        COMPREPLY=( \$(compgen -W "$OPTIONAL_NAMES" -- "\$cur") )
    fi
}
complete -F _cc_complete cc
$MARK_END
EOF

ok "Registered cc aliases + dispatcher in $BASHRC (run 'source ~/.bashrc' or open a new shell)"

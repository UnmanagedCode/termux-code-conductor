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
# Subcommand form:   cc start|stop|logs|update|projects
# Shortcut aliases:  cc-start, cc-stop, cc-logs, cc-update, cc-projects
cc-start() {
    ( cd "$CC_DIR" && PROJECTS_ROOT="$CC_PROJECTS_DIR" nohup npm start >server.log 2>&1 & ) \\
        && echo "Code Conductor starting at $CC_LOCAL_URL (logs: $CC_DIR/server.log)"
}
cc-stop() {
    pkill -f "node $CC_DIR/server.js" && echo "Code Conductor stopped" || echo "no Code Conductor process running"
}
cc-logs() { tail -f "$CC_DIR/server.log"; }
cc-update() { bash "$REPO/update.sh" "\$@"; }
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
        projects) cc-projects "\$@" ;;
        ''|-h|--help)
            echo "Usage: cc {start|stop|logs|update|projects}"
            ;;
        *)
            echo "cc: unknown subcommand '\$sub'" >&2
            echo "Usage: cc {start|stop|logs|update|projects}" >&2
            return 2
            ;;
    esac
}

# Bash completion for the dispatcher (first-arg subcommand only)
_cc_complete() {
    local cur="\${COMP_WORDS[COMP_CWORD]}"
    if [ "\$COMP_CWORD" = "1" ]; then
        COMPREPLY=( \$(compgen -W "start stop logs update projects" -- "\$cur") )
    fi
}
complete -F _cc_complete cc
$MARK_END
EOF

ok "Registered cc aliases + dispatcher in $BASHRC (run 'source ~/.bashrc' or open a new shell)"

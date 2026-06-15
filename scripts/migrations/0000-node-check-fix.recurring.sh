#!/data/data/com.termux/files/usr/bin/bash
# Recurring reconciler: ensure the node wrapper exempts --check/--eval/--print/
# --interactive/--input-type from NODE_OPTIONS hoisting (fix for pre-11079ca wrappers).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

_NODE_WRAPPER="$HOME/claude-code-android/bin/node"

[ -f "$_NODE_WRAPPER" ] || exit 0

grep -qF -- '--check|--eval|--print|--interactive|--input-type' "$_NODE_WRAPPER" && exit 0

log "node wrapper missing --check exemption — patching in place"

# These two lines match exactly what write_wrappers() in vendor/claude-install.sh
# now emits (commit 11079ca). They are inserted immediately before the --*) arm
# in the flag-hoisting while loop (first occurrence only — single-match guard).
_LINE1='            --check|--eval|--print|--interactive|--input-type)'
_LINE2='                break ;;   # not allowed in NODE_OPTIONS — leave in $@ for node.real'
_TMP="$(mktemp)"
awk -v line1="$_LINE1" -v line2="$_LINE2" '
/^[[:space:]]+--\*\) _LEADING_OPTS=/ && !done {
    done = 1
    print line1
    print line2
}
{ print }
' "$_NODE_WRAPPER" > "$_TMP"

if ! grep -qF -- '--check|--eval|--print|--interactive|--input-type' "$_TMP"; then
    rm -f "$_TMP"
    warn "node wrapper patch did not apply (anchor line not found) — skipping"
    exit 1
fi

mv "$_TMP" "$_NODE_WRAPPER"
chmod 755 "$_NODE_WRAPPER"
ok "node wrapper patched — --check and friends no longer hoisted into NODE_OPTIONS"

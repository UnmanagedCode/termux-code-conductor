#!/data/data/com.termux/files/usr/bin/bash
# Recurring reconciler: ensure the node wrapper exempts --test from NODE_OPTIONS
# hoisting (fix for pre-0002 wrappers).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

_NODE_WRAPPER="$HOME/claude-code-android/bin/node"

[ -f "$_NODE_WRAPPER" ] || exit 0

grep -qF -- '--input-type|--test)' "$_NODE_WRAPPER" && exit 0

log "node wrapper missing --test exemption — patching in place"

_TMP="$(mktemp)"
sed 's/--check|--eval|--print|--interactive|--input-type)/--check|--eval|--print|--interactive|--input-type|--test)/' \
    "$_NODE_WRAPPER" > "$_TMP"

if ! grep -qF -- '--input-type|--test)' "$_TMP"; then
    rm -f "$_TMP"
    warn "node wrapper patch did not apply (anchor line not found) — skipping"
    exit 1
fi

mv "$_TMP" "$_NODE_WRAPPER"
chmod 755 "$_NODE_WRAPPER"
ok "node wrapper patched — --test no longer hoisted into NODE_OPTIONS"

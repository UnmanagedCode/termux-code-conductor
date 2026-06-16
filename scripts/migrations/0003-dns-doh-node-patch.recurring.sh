#!/data/data/com.termux/files/usr/bin/bash
# Recurring reconciler: re-apply the dns-doh wrapper patch to the NODE wrapper
# when missing. A full CLI reinstall regenerates bin/node (write_wrappers() in
# vendor/claude-install.sh), wiping the patch. 0001 guards on the claude marker
# and early-exits once claude is patched, so it won't notice a node wrapper that
# lost its block — hence this separate node-guarded reconciler. Sorts after 0000
# and 0002 (which patch the node wrapper's flag-hoisting loop), so it always runs
# on the final wrapper form.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

_DOH_SO="$HOME/claude-code-android/dns-doh/dohshim.so"
_NODE_WRAPPER="$HOME/claude-code-android/bin/node"

[ -f "$_DOH_SO" ]        || exit 0
[ -f "$_NODE_WRAPPER" ]  || exit 0
grep -qF '# >>> dns-doh shim >>>' "$_NODE_WRAPPER" && exit 0

log "dns-doh installed but node wrapper patch missing — re-applying"
bash "$HERE/../install-dns-doh.sh" --patch-only

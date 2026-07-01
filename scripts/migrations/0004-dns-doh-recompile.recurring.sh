#!/data/data/com.termux/files/usr/bin/bash
# Recurring reconciler: recompile dohshim.so when the checked-out source is newer
# than the installed shim (e.g. after a git pull that changed dohshim.c). cc
# upgrade npm-upgrades the CLI and re-patches the wrappers (0001/0003) but never
# rebuilds the compiled .so — so a shim source fix (e.g. the connect() interposer)
# would otherwise stay stale until a manual `cc install dns-doh`. Wrapper patching
# is owned by 0001/0003; this migration is single-purpose (rebuild the .so only).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

_DOH_SO="$HOME/claude-code-android/dns-doh/dohshim.so"
_SRC="$HERE/../dns-doh/dohshim.c"

# dns-doh is opt-in: never auto-install it on a host that never chose it (same
# philosophy as 0001's [ -f "$_DOH_SO" ] || exit 0).
[ -f "$_DOH_SO" ]                || exit 0
[ -f "$_SRC" ]                   || exit 0
command -v clang >/dev/null 2>&1 || exit 0

# Source not newer than the compiled shim → nothing to do. After a git pull that
# touched the .c, its fresh mtime > the old .so triggers exactly one recompile;
# unchanged source on later updates is a no-op. The recompile's atomic swap is
# safe under running sessions.
[ "$_SRC" -nt "$_DOH_SO" ] || exit 0

log "dns-doh source newer than compiled shim — recompiling"
bash "$HERE/../install-dns-doh.sh" --compile-only

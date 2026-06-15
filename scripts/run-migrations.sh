#!/data/data/com.termux/files/usr/bin/bash
# Discover and run migration scripts from scripts/migrations/.
# Called by update.sh after every update.
#
# Naming convention:
#   NNNN-<name>.once.sh       — run once; completion recorded in .state/migrations/
#   NNNN-<name>.recurring.sh  — run every update; idempotent; no state recorded
#
# Error semantics: a failing migration emits a warning and is skipped; the runner
# never aborts the update. The runner itself always exits 0.

set -euo pipefail
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RUNNER_DIR/lib.sh"

MIGRATIONS_DIR="$RUNNER_DIR/migrations"
STATE_DIR="$HOME/claude-code-android/.state/migrations"

[ -d "$MIGRATIONS_DIR" ] || exit 0

shopt -s nullglob
migrations=( "$MIGRATIONS_DIR"/*.sh )
shopt -u nullglob
[ "${#migrations[@]}" -eq 0 ] && exit 0

mkdir -p "$STATE_DIR"

_failures=0
for mig in "${migrations[@]}"; do
    name="$(basename "$mig")"
    case "$name" in
        *.once.sh)
            key="${name%.once.sh}"
            [ -f "$STATE_DIR/$key" ] && continue
            if ( bash "$mig" ); then
                touch "$STATE_DIR/$key"
            else
                warn "Migration $name failed — continuing"
                _failures=$((_failures + 1))
            fi
            ;;
        *.recurring.sh)
            if ! ( bash "$mig" ); then
                warn "Reconciler $name failed — continuing"
                _failures=$((_failures + 1))
            fi
            ;;
        *)
            warn "Migration $name: unknown type (expected .once.sh or .recurring.sh) — skipping"
            ;;
    esac
done

[ "$_failures" -gt 0 ] && warn "$_failures migration(s) failed — see warnings above"
exit 0

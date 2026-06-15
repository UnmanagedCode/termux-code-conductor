#!/data/data/com.termux/files/usr/bin/bash
# Discover and run recurring migration scripts from scripts/migrations/.
# Called by update.sh after every update.
#
# Only *.recurring.sh files are supported — they run every update and must be
# idempotent. One-time (.once.sh) migration support will be added when a
# genuine one-time migration is first required.
#
# Error semantics: a failing reconciler emits a warning and is skipped; the
# runner never aborts the update. The runner itself always exits 0.

set -euo pipefail
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RUNNER_DIR/lib.sh"

MIGRATIONS_DIR="$RUNNER_DIR/migrations"

[ -d "$MIGRATIONS_DIR" ] || exit 0

shopt -s nullglob
migrations=( "$MIGRATIONS_DIR"/*.sh )
shopt -u nullglob
[ "${#migrations[@]}" -eq 0 ] && exit 0

_failures=0
for mig in "${migrations[@]}"; do
    name="$(basename "$mig")"
    case "$name" in
        *.recurring.sh)
            if ! ( bash "$mig" ); then
                warn "Reconciler $name failed — continuing"
                _failures=$((_failures + 1))
            fi
            ;;
        *)
            warn "Migration $name: only .recurring.sh is supported right now (once-flow not implemented) — skipping"
            ;;
    esac
done

[ "$_failures" -gt 0 ] && warn "$_failures migration(s) failed — see warnings above"
exit 0

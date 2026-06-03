#!/data/data/com.termux/files/usr/bin/bash
# Shared helpers for bootstrap scripts.
# Source this file: source "$(dirname "$0")/lib.sh"

set -euo pipefail

if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m'; C_NC=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_NC=''
fi

log()  { printf '%s[bootstrap]%s %s\n' "$C_BLU" "$C_NC" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_NC" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_NC" "$*" >&2; }
die()  { printf '%s[err]%s %s\n' "$C_RED" "$C_NC" "$*" >&2; exit 1; }

require_termux() {
    [ "${PREFIX:-}" = "/data/data/com.termux/files/usr" ] \
        || die "Not running inside Termux (PREFIX=$PREFIX). Install Termux from F-Droid first."
    [ "$(uname -m)" = "aarch64" ] \
        || die "Unsupported arch $(uname -m). Only aarch64 Android is supported."
}

# ── Optional add-on projects ────────────────────────────────────────────────
# Registry of optional projects installable on demand via `cc install <name>`.
# Each is cloned into ~/cc-projects, tagged CC-Dev, and (if it ships a
# package.json) npm-installed. This table is the single source of truth — the
# installer, the updater, and the `cc install` listing all read from it.
# One row per project, tab-separated: <canonical-name> <git-url> <description>
optional_projects_table() {
    printf '%s\t%s\t%s\n' \
        code-share \
        "https://github.com/UnmanagedCode/code-share.git" \
        "Peer-to-peer read-only Git repo sharing over LAN/internet (web UI :9420)"
    printf '%s\t%s\t%s\n' \
        termux-playwright-harness \
        "https://github.com/UnmanagedCode/termux-playwright-harness.git" \
        "Playwright + Termux-Chromium glue for visual UI debugging from a phone"
}

# Print every optional project's canonical name, one per line.
optional_project_names() { optional_projects_table | cut -f1; }

# Map a user-given name (or short alias) to its canonical name on stdout.
# Returns 1 if the name isn't a known optional project.
canonical_optional_project() {
    case "$1" in
        code-share|codeshare|share)                   echo code-share ;;
        playwright|harness|termux-playwright-harness)  echo termux-playwright-harness ;;
        *) return 1 ;;
    esac
}

# Print the git URL for a canonical optional-project name. Returns 1 if unknown.
optional_project_url() {
    optional_projects_table \
        | awk -F'\t' -v n="$1" '$1==n {print $2; found=1} END {exit !found}'
}

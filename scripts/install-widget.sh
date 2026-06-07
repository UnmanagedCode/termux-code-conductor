#!/data/data/com.termux/files/usr/bin/bash
# Install a Termux:Widget background-task shortcut that starts Code Conductor.
# Placed in ~/.shortcuts/tasks/ (silent background task) so Termux:Widget runs
# it without opening a terminal. Requires "Display over other apps" permission
# for the background task to open Chrome (Android 10+ BAL rules). Idempotent.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

require_termux

SHORTCUTS_DIR="$HOME/.shortcuts"
TASKS_DIR="$HOME/.shortcuts/tasks"
ICONS_DIR="$HOME/.shortcuts/icons"
WIDGET_SCRIPT="$TASKS_DIR/CodeConductor"
REPO_ICON="$HERE/../assets/widget-icon.png"

# Migrate: remove all stale shortcut variants (including the old top-level deploy)
# so re-running never leaves duplicates.
_stale=0
for _f in \
    "$HOME/.shortcuts/tasks/Code Conductor.sh" \
    "$HOME/.shortcuts/Code Conductor.sh" \
    "$HOME/.shortcuts/Code Conductor" \
    "$HOME/.shortcuts/Code_Conductor" \
    "$HOME/.shortcuts/CodeConductor"; do
    [ -e "$_f" ] && { rm -f "$_f"; _stale=1; }
done
# stale icon files (harmless if absent; don't affect the warn)
rm -f "$HOME/.shortcuts/icons/tasks/Code Conductor.sh.png" \
      "$HOME/.shortcuts/icons/tasks/Code Conductor.png" \
      "$HOME/.shortcuts/icons/Code Conductor.sh.png" \
      "$HOME/.shortcuts/icons/Code Conductor.png" \
      "$HOME/.shortcuts/icons/Code_Conductor.png" \
      "$HOME/.shortcuts/icons/CodeConductor.png"
[ "$_stale" -eq 1 ] && warn "Removed stale shortcut variant(s) — refresh/re-add the widget to pick up the new entry"

log "Installing Termux:Widget background task → $WIDGET_SCRIPT"

mkdir -p "$TASKS_DIR"

# Write the shortcut script that Termux:Widget executes on tap.
# Placed in ~/.shortcuts/tasks/ (background task, no terminal) — requires
# Termux "Display over other apps" (SYSTEM_ALERT_WINDOW) permission so that
# the background task can open Chrome (Android 10+ BAL rules).
cat > "$WIDGET_SCRIPT" << 'SHORTCUT'
#!/data/data/com.termux/files/usr/bin/bash

# Acquire a wake lock so the server survives screen-off / Termux backgrounding.
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock

# Delegate to the canonical cc dispatcher (defined in ~/.bashrc by register-alias.sh).
bash -i -c "cc start" 2>/dev/null

# Wait up to 10s for the server to be ready before opening the browser.
for _i in $(seq 1 10); do
    curl -sf --max-time 1 -o /dev/null http://127.0.0.1:8787 && break
    sleep 1
done

# Open Code Conductor in the system default browser. Requires "Display over
# other apps" permission for the background task to satisfy Android 10+ BAL rules.
am start -a android.intent.action.VIEW -d 'http://127.0.0.1:8787' 2>/dev/null || true

# Toast is optional (requires Termux:API app). Time-bounded so its absence is harmless.
command -v termux-toast >/dev/null 2>&1 && \
    timeout 3 termux-toast -g middle \
        "Code Conductor running at http://127.0.0.1:8787" \
        >/dev/null 2>&1 || true
SHORTCUT

chmod +x "$WIDGET_SCRIPT"
ok "Background task installed: $WIDGET_SCRIPT"

# Install the widget icon. Termux:Widget looks for <name>.png in either
# ~/.shortcuts/icons/ or ~/.shortcuts/icons/tasks/ depending on version;
# copy to both to ensure compatibility.
if [ -f "$REPO_ICON" ]; then
    mkdir -p "$ICONS_DIR" "$ICONS_DIR/tasks"
    cp "$REPO_ICON" "$ICONS_DIR/CodeConductor.png"
    cp "$REPO_ICON" "$ICONS_DIR/tasks/CodeConductor.png"
    ok "Widget icon installed → $ICONS_DIR/CodeConductor.png and $ICONS_DIR/tasks/CodeConductor.png"
else
    warn "Icon asset not found at $REPO_ICON — widget will show the default Termux icon"
fi

# Check whether Termux has the overlay (SYSTEM_ALERT_WINDOW) permission.
# Without it, a background task cannot open the browser under Android 10+ BAL rules.
_overlay_ok=0
if command -v appops >/dev/null 2>&1; then
    appops get com.termux SYSTEM_ALERT_WINDOW 2>/dev/null | grep -qi "allow" && _overlay_ok=1
fi
if [ "$_overlay_ok" -eq 0 ]; then
    warn "*** ACTION REQUIRED: Grant 'Display over other apps' permission to Termux ***"
    warn "The background task needs this permission to open the browser (Android 10+ BAL rules)."
    warn "Without it, the server will still start but the browser will NOT open automatically."
    warn "Steps: Settings → Apps → Termux → 'Display over other apps' (a.k.a. 'Appear on top') → Allow"
fi

log "Background task runs silently — no terminal window will open on tap."
log "Requires 'Display over other apps' permission (see above) for browser auto-open."
log "If you had an older shortcut pinned, you must RE-PIN it — the script moved to tasks/."
log "Refresh or re-add the Termux:Widget list to pick up the new shortcut location."
log "(Optional) Install 'Termux:API' from F-Droid to enable the confirmation toast."
log "Requires Termux:Widget add-on app (F-Droid: https://f-droid.org/packages/com.termux.widget/)"

log "Opening Termux:Widget 'create shortcut' screen — tap CodeConductor to pin it to your home screen."
am start -n com.termux.widget/.TermuxCreateShortcutActivity >/dev/null 2>&1 || true

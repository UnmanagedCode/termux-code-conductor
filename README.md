# termux-code-conductor

One-shot installer that gets [Claude Code CLI](https://github.com/anthropics/claude-code) **and** [Code Conductor](https://github.com/UnmanagedCode/code-conductor) (**CC** — a local multi-agent orchestrator for Claude) running on a fresh Termux session.

## What you get

After running the bootstrap on a clean device you have:

- `claude` on `$PATH` — runs natively under glibc-runner on Android aarch64.
- Code Conductor cloned to `~/cc-projects/code-conductor`, deps installed, server running at <http://127.0.0.1:8787>, configured to use `~/cc-projects/` as its projects root.
- `~/cc-projects/CLAUDE.md` containing the workspace conventions — created and managed by Code Conductor on first run (Settings → Workspace conventions). Auto-imported by every project's local `CLAUDE.md` via `@../CLAUDE.md`.
- The bootstrap repo, Code Conductor, and (optionally) the Playwright harness all tagged as the **CC-Dev** group inside the CC UI — so they group together visually, separate from your own projects.
- A `cc` dispatcher function with tab completion, plus matching `cc-*` shortcut aliases (`cc-start`, `cc-stop`, `cc-logs`, `cc-update`, `cc-upgrade`, `cc-install`, `cc-projects`) registered in `~/.bashrc`.

## Requirements

- Android device, **aarch64**.
- [Termux](https://termux.dev) (see *Install Termux* below — the Play Store version is unmaintained, use F-Droid or GitHub).
- ~1.5 GB free in `$HOME`.
- Working internet (the installer fetches the Node.js tarball + npm packages + clones the CC repo).

## Install Termux

The Google Play version of Termux is **frozen** and won't work. Install from one of:

1. **F-Droid** (recommended) — install the [F-Droid client APK](https://f-droid.org/F-Droid.apk) from f-droid.org, then search "Termux" inside F-Droid and install. Updates flow through F-Droid.
2. **Direct APK** (no F-Droid client needed) — download the F-Droid-signed APK directly: [com.termux_1022.apk](https://f-droid.org/repo/com.termux_1022.apk) (package page: <https://f-droid.org/packages/com.termux/>). Allow installs from your browser/file manager and sideload.
3. **GitHub releases** — download the latest `termux-app_*.apk` for `arm64-v8a` from <https://github.com/termux/termux-app/releases> and sideload. You'll need to allow installs from your browser/file manager.

## One-liner

> Inspect the script first if you don't trust it: `curl -fsSL https://raw.githubusercontent.com/UnmanagedCode/termux-code-conductor/main/bootstrap.sh | less`

```bash
curl -fsSL https://raw.githubusercontent.com/UnmanagedCode/termux-code-conductor/main/bootstrap.sh | bash
```

The script prompts interactively `[y/N]` for each [optional project](#optional-projects-cc-install) (code-share, the Playwright harness, …), and at the end offers to open the CC UI in your browser. Use flags to skip the prompts:

```bash
# install specific optional projects, no prompt (comma-separated; aliases ok)
curl -fsSL .../bootstrap.sh | bash -s -- --with=code-share,playwright

# fully non-interactive (installs no optional projects)
curl -fsSL .../bootstrap.sh | bash -s -- -y
```

When piped, the script clones itself to `~/cc-projects/termux-code-conductor` and re-execs. The interactive prompts read from `/dev/tty`, so they still work even when stdin is the curl pipe.

## Manual install

```bash
pkg install -y git
git clone https://github.com/UnmanagedCode/termux-code-conductor.git ~/cc-projects/termux-code-conductor
cd ~/cc-projects/termux-code-conductor
./bootstrap.sh                            # interactive [y/N] per optional project
./bootstrap.sh --with=code-share          # install code-share, no prompt
./bootstrap.sh --with=code-share,playwright  # multiple (comma-separated; aliases ok)
./bootstrap.sh -y                         # non-interactive, no optional projects
```

### Flags

| Flag | Meaning |
|---|---|
| `--with=<name,...>` | Install these optional projects (comma-separated, repeatable). Skips the prompts. Names/aliases come from the registry in `scripts/lib.sh` (e.g. `code-share`, `playwright`). |
| `-y`, `--yes`, `--non-interactive` | Never prompt. Installs **no** optional projects (unless `--with=` is also given) and **does not** open the browser. |
| `-h`, `--help` | Print the header comment and exit. |

## What the bootstrap actually does

`bootstrap.sh` runs `install-claude-cli.sh`, `install-cc.sh`, then one `install-optional.sh <name>` per selected optional project, then `register-alias.sh`. Each is idempotent — re-running the bootstrap is safe.

| Step | Script | What it does |
|---|---|---|
| 1 | `scripts/install-claude-cli.sh` | If `~/claude-code-android/bin/claude -v` already works, skip. Otherwise run the vendored 12-step installer (`scripts/vendor/claude-install.sh`) that sets up `glibc-runner`, downloads Node 22.22.0 arm64, applies the openclaw-android `glibc-compat.js` patch, and `npm install -g @anthropic-ai/claude-code`. Appends a `PATH` block to `~/.bashrc`. |
| 2 | `scripts/install-cc.sh` | Creates `~/cc-projects/`. `git clone https://github.com/UnmanagedCode/code-conductor.git ~/cc-projects/code-conductor` (or `git pull`). Registers the clone in Code Conductor's central store at `~/cc-projects/.code-conductor/projects/code-conductor/project.json` with `{"group": "CC-Dev"}`. `npm install`, then `PROJECTS_ROOT=~/cc-projects nohup npm start` in the background. Logs to `~/cc-projects/code-conductor/server.log`. Waits up to 10 s for `127.0.0.1:8787` to respond. Code Conductor creates `~/cc-projects/CLAUDE.md` on first start. |
| 3…N | `scripts/install-optional.sh <name>` | **One per project selected via `--with=` or the interactive prompts.** Clone into `~/cc-projects/`, tag `CC-Dev`, `npm install` if it has a `package.json`. Projects with extra system deps delegate to a dedicated installer: `code-share` → `install-code-share.sh` (also `pkg install -y cloudflared`); the harness → `install-playwright.sh` (also `pkg install -y chromium`). See [Optional projects](#optional-projects-cc-install). |
| last | `scripts/register-alias.sh` | Rewrites a managed `# >>> code-conductor aliases >>>` block in `~/.bashrc` with the `cc` dispatcher function, bash completion, and `cc-start`/`cc-stop`/`cc-logs`/`cc-update`/`cc-upgrade`/`cc-install`/`cc-projects`/`cc-widget` shortcut aliases. |

Why glibc-runner? Termux ships musl-style bionic libc, but Claude Code (and Node) ship as glibc binaries. `glibc-runner` provides `ld-linux-aarch64.so.1` and a glibc tree so unmodified Linux/arm64 binaries run inside Termux. The vendored installer also patches Node with `glibc-compat.js` to handle a couple of Android filesystem quirks. Full background lives in [openclaw-android](https://github.com/AidanPark/openclaw-android).

## Using Code Conductor

```bash
source ~/.bashrc      # only needed once, to pick up the new aliases

cc start              # or: cc-start   — background-start the server
cc logs               # or: cc-logs    — follow logs in another pane (Ctrl-C to detach)
cc stop               # or: cc-stop    — shut it down
cc update             # or: cc-update  — pull repos + reapply bootstrap steps
cc upgrade            # or: cc-upgrade — cc update + force-upgrade Claude CLI
cc install <name>     # or: cc-install — install an optional project (no arg → list)
cc projects           # or: cc-projects — cd into ~/cc-projects
cc widget             # or: cc-widget  — install the Termux:Widget home-screen shortcut

# Tab completion works on the subcommands (and on optional-project names after `install`):
cc <TAB>              # → start  stop  logs  update  upgrade  install  projects  widget
cc install <TAB>      # → code-share  termux-playwright-harness  dns-doh
```

Then browse to <http://127.0.0.1:8787>. The CC UI lists everything under `~/cc-projects/` and groups the bootstrap, Code Conductor, and the harness under **CC-Dev** so they don't clutter your own projects.

## Termux:Widget home-screen shortcut

Tap a home-screen widget to start CC and open it in the system default browser — silently, with no terminal window.

**Prerequisites:**
- Install the **Termux:Widget** add-on app from F-Droid (not the Play Store):
  [▶ Termux:Widget on F-Droid](https://f-droid.org/packages/com.termux.widget/)
- Grant Termux the **"Display over other apps"** permission (SYSTEM_ALERT_WINDOW). Without it the server will still start on tap, but the browser will **not** open automatically (Android 10+ Background-Activity-Launch rules block foreground launches from a background task unless the app holds this permission). To grant it: **Settings → Apps → Termux → "Display over other apps"** (a.k.a. "Appear on top") → **Allow**.

**Install the shortcut:**

```bash
cc widget            # or: bash ~/cc-projects/termux-code-conductor/scripts/install-widget.sh
```

This writes `~/.shortcuts/tasks/CodeConductor` (a silent background task) and installs a custom icon. Re-running is safe (idempotent). The installer removes any stale variants (`~/.shortcuts/tasks/Code Conductor.sh`, `~/.shortcuts/Code Conductor.sh`, `~/.shortcuts/Code Conductor`, `~/.shortcuts/Code_Conductor`, `~/.shortcuts/CodeConductor`) automatically. At the end, it opens the Termux:Widget "create shortcut" screen so you can immediately pin CodeConductor to your home screen.

**Re-pin after upgrade:** the script moved from `~/.shortcuts/` to `~/.shortcuts/tasks/` — if you had a previous shortcut pinned you must remove it and re-pin **CodeConductor** from the widget list.

**Add to home screen:** `cc widget` opens the Termux:Widget "create shortcut" screen automatically at the end of install — tap **CodeConductor** (shown with the CC icon) to pin it. Alternatively: long-press an empty area of your home screen → **Widgets** → **Termux:Widget** → tap **CodeConductor**.

**What happens on tap (silent background task — no terminal):**
1. Acquires a `termux-wake-lock` so the server survives screen-off and Termux backgrounding.
2. Calls `cc start` — no-op if the server is already running.
3. Waits up to 10 s for the server to be ready (instant on a warm start).
4. Opens `http://127.0.0.1:8787` in the system default browser. Requires "Display over other apps" permission (see above) for this to work from a background task.
5. Shows a toast (optional, requires Termux:API app).

If the browser doesn't open automatically, the "Display over other apps" permission is likely missing — open `http://127.0.0.1:8787` yourself in any browser, or install a PWA from that URL.

**To stop:** run `cc stop` to kill the server, then `termux-wake-unlock` to release the wake lock (or force-stop Termux from Android settings, which releases it automatically).

**Technical notes:**
- **Icon:** `assets/widget-icon.png` (192×192 PNG, rasterized from Code Conductor's own `public/icon.svg`) is copied to both `~/.shortcuts/icons/CodeConductor.png` and `~/.shortcuts/icons/tasks/CodeConductor.png` — Termux:Widget looks in either location depending on version.
- **Browser launch:** uses `am start -a android.intent.action.VIEW` without a package constraint, so the system default browser handles the URL. `am start` calls Android's Activity Manager directly from within Termux — it does **not** require `allow-external-apps=true` in `termux.properties` (unlike `termux-open-url`). Android 10+ BAL rules normally block background tasks from foregrounding other apps, but granting Termux SYSTEM_ALERT_WINDOW ("Display over other apps") exempts it, allowing the default browser to open reliably.
- **Toast:** `termux-toast` requires the Termux:API app (F-Droid: `com.termux.api`). It is optional — the call uses a 3-second timeout (`timeout 3 termux-toast …`) so its absence is harmless.

CC's own README (full feature list, REST + WebSocket protocol, MCP wiring) lives at <https://github.com/UnmanagedCode/code-conductor/blob/main/README.md>.

## Optional projects (`cc install`)

Add-on projects that aren't part of the core install. `cc install <name>` clones one into `~/cc-projects/`, tags it as the **CC-Dev** group, and `npm install`s its deps if it ships a `package.json`. Re-running just fast-forwards + reinstalls (idempotent). `cc install` with no argument lists what's available and which are already installed.

| Name | What it is |
|---|---|
| `code-share` | [code-share](https://github.com/UnmanagedCode/code-share) — peer-to-peer **read-only** Git repo sharing over LAN/internet. Each party serves repos read-only and pulls from peers; no pushes. Git server on `:9419` (tunnelable via cloudflared), web UI on `:9420` (localhost only). Run it with `node bin/code-share.js serve` from `~/cc-projects/code-share`. |
| `termux-playwright-harness` | The Playwright harness (see below). Aliased as `playwright`/`harness`. Routed through the dedicated installer because it also needs the Termux `chromium` package. |
| `dns-doh` | DNS-over-HTTPS fallback for Claude Code on captive/hotel networks that block external port 53. Compiles a small C `LD_PRELOAD` shim from source at install time and patches the `claude` wrapper. Aliased as `doh`. See [DNS fix for captive networks](#dns-fix-for-captive-networks-cc-install-dns-doh). |

```bash
cc install                 # list available optional projects + install status
cc install code-share      # clone + npm install code-share
cc install playwright      # alias → termux-playwright-harness (full chromium setup)
cc install dns-doh         # compile + install the DoH DNS shim (alias: doh)
```

The registry is the single source of truth in `scripts/lib.sh` (`optional_projects_table`); `cc install`, tab completion, and `update.sh` all read from it, so `cc update` also `git pull`s every installed optional project.

## Optional: Playwright harness

Install it via `cc install playwright`, `bootstrap.sh --with=playwright`, or the interactive prompt — any of which routes to `install-playwright.sh` to set up the [termux-playwright-harness](https://github.com/UnmanagedCode/termux-playwright-harness) — Playwright + Termux Chromium glue for visual UI debugging from a phone. It installs:

- Termux's `x11-repo` (where the `chromium` package lives — not the default `termux-main`), and then the `chromium` package itself (provides `chromium-browser`).
- A clone of the harness at `~/cc-projects/termux-playwright-harness`, tagged as `CC-Dev`.
- Its npm deps (`playwright-core` only — the harness points `executablePath` at the system Chromium, which sidesteps Playwright's normal Chromium auto-download that doesn't ship arm64-Android builds).

The harness is a library, not a server — sibling projects import directly from `~/cc-projects/termux-playwright-harness/browser.mjs`. Nothing starts in the background. `cc update` will `git pull` it too, but only if you've actually installed it.

## DNS fix for captive networks (`cc install dns-doh`)

Claude Code resolves DNS through glibc → hardcoded 8.8.8.8/8.8.4.4. Hotel/captive Wi-Fi networks that block external port 53 cause every API call to fail with `EAI_AGAIN` / "FailedToOpenSocket", even though HTTPS/443 works fine. This feature fixes it.

```bash
cc install dns-doh      # compile + install (alias: cc install doh)
```

**What it installs:**

- Compiles `scripts/dns-doh/dohshim.c` into `~/claude-code-android/dns-doh/dohshim.so` using `clang` (installed automatically as a build dep for this feature only — not part of the default install).
- Patches the `claude` wrapper (`~/claude-code-android/bin/claude`) to `LD_PRELOAD` the shim into Claude's glibc process. The patch is idempotent and guarded: `[ -f "$_DOH_SHIM" ] && export LD_PRELOAD=...` — harmless if the shim is absent.

**How it works:** the shim intercepts `getaddrinfo()`. Fast path: tries the system resolver first — zero overhead on healthy networks. On failure, falls back to `curl https://1.1.1.1/dns-query` (port 443), synthesizes a glibc-compatible `addrinfo` chain, and returns it. Cloudflare's DoH endpoint is used; `curl` is Termux's bionic binary (uses Android's own resolver, bypasses the blocked port 53).

**Validate:**

```bash
CLAUDE_DOH_FORCE=1 claude --version   # forces DoH-only; proves DoH resolution works
```

**Uninstall:**

```bash
cc install dns-doh --uninstall        # removes .so + wrapper patch
# pkg remove clang                    # optional: remove clang if no longer needed
```

**Wrapper re-generation:** the `claude` wrapper is only regenerated during a full fresh Claude CLI install. `cc upgrade` (`npm install -g @latest`) does **not** touch the wrapper. `cc update` automatically re-applies the patch if it detects the shim is present but the patch is missing. After a manual wipe (`rm -rf ~/claude-code-android`) and reinstall, re-run `cc install dns-doh`.

## Updating

```bash
cc update                   # or: cc-update    or: bash ~/cc-projects/termux-code-conductor/update.sh
cc upgrade                  # or: cc-upgrade   — same as `cc update --cli`
```

`update.sh` does the right thing for every component:

1. `git pull --ff-only` the bootstrap repo, Code Conductor, and every installed optional project (the harness, code-share, …); prints which files changed.
2. Re-runs `register-alias.sh` (no-op if `~/.bashrc` is already current).
3. If CC's or any installed optional project's `package.json`/lockfile changed → `npm install` in that dir.
4. If CC code changed and the server is running → graceful restart with `PROJECTS_ROOT=~/cc-projects`.
5. Only re-runs the Claude CLI installer if `scripts/vendor/claude-install.sh` itself changed.

**Flags:**

- `--cli` — also force-upgrade the Claude CLI to the latest npm release (`npm i -g @anthropic-ai/claude-code@latest`). Useful when Anthropic ships a new version even though nothing in this repo changed. `cc upgrade` is shorthand for `cc update --cli`.
- `--no-restart` — pull and reinstall deps but don't bounce the running server.

## Uninstall

```bash
cc-stop || true
rm -rf ~/claude-code-android
rm -rf ~/cc-projects/code-conductor
rm -rf ~/cc-projects/termux-playwright-harness   # only if the harness was installed
rm -rf ~/cc-projects/code-share                  # only if code-share was installed
cc install dns-doh --uninstall                   # only if dns-doh was installed
# Hand-edit ~/.bashrc and remove the two managed blocks:
#   # >>> claude-code-android (PATH only) >>>  ...  # <<< ... <<<
#   # >>> code-conductor aliases >>>           ...  # <<< ... <<<
```

To also wipe the projects root: `rm -rf ~/cc-projects` — but that'll take everything you've put under there, so check first.

## Known limitations

- **aarch64 only.** No 32-bit ARM, no x86 emulator support. The installer hard-fails on anything else.
- **Localhost-only CC.** Server binds `127.0.0.1:8787` with no auth. Don't `ssh -L` it to a shared box.
- **Background server dies on session end.** Termux kills its process tree when the app is force-stopped. Wrap the server in `tmux` or hold a `termux-wake-lock` if you want it persistent.
- **Wake lock is not auto-released.** The Termux:Widget shortcut acquires a `termux-wake-lock` on each tap. Run `termux-wake-unlock` when you no longer need the server running in the background, or stop it via `cc stop && termux-wake-unlock`. Force-stopping Termux from Android settings releases it automatically.
- **"Display over other apps" permission required for browser auto-open.** The shortcut runs as a silent background task (`~/.shortcuts/tasks/`), which means Android 10+ BAL rules block it from foregrounding the default browser unless Termux holds the SYSTEM_ALERT_WINDOW permission. Grant it via **Settings → Apps → Termux → "Display over other apps" (a.k.a. "Appear on top") → Allow**. Without it, the server still starts but the browser won't open automatically; navigate to `http://127.0.0.1:8787` yourself.
- **Re-pin required after upgrade from the old shortcut.** The script moved from `~/.shortcuts/CodeConductor` to `~/.shortcuts/tasks/CodeConductor`. Any previously pinned shortcut must be removed and re-added from the widget list.
- **First install is slow.** The 12-step installer downloads ~50 MB (Node tarball) plus the global npm install. Expect 3–10 minutes on a fresh device depending on network.
- **Captive/hotel Wi-Fi blocks DNS.** Claude Code resolves via glibc → hardcoded 8.8.8.8/8.8.4.4. Networks that block external port 53 cause `EAI_AGAIN` / "FailedToOpenSocket" on every API call, even when HTTPS works. Fix: `cc install dns-doh`.

## Repo layout

```
.
├── assets/
│   └── widget-icon.png         # 192×192 PNG icon, rasterized from code-conductor/public/icon.svg
├── bootstrap.sh            # entrypoint
├── update.sh               # git pull + re-apply (use `cc update`)
├── scripts/
│   ├── lib.sh              # shared logging + Termux guard
│   ├── install-claude-cli.sh
│   ├── install-cc.sh           # clones Code Conductor, sets group, starts server
│   ├── install-optional.sh     # cc install <name>: clone+tag+npm an optional project
│   ├── install-code-share.sh   # optional: clones code-share + pkg install cloudflared
│   ├── install-playwright.sh   # optional: clones termux-playwright-harness (chromium setup)
│   ├── install-dns-doh.sh      # optional: compile + install DoH DNS shim for Claude
│   ├── dns-doh/
│   │   └── dohshim.c           # LD_PRELOAD getaddrinfo() interposer source (compiled at install)
│   ├── install-widget.sh       # Termux:Widget home-screen shortcut (cc widget)
│   ├── register-alias.sh       # cc dispatcher + completion + cc-* aliases
│   └── vendor/
│       └── claude-install.sh           # vendored from ~/share/claude-install.sh
├── .gitignore
├── CLAUDE.md
└── README.md
```

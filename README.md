# termux-code-conductor

One-shot installer that gets [Claude Code CLI](https://github.com/anthropics/claude-code) **and** [Code Conductor](https://github.com/UnmanagedCode/code-conductor) (**CC** — a local multi-agent orchestrator for Claude) running on a fresh Termux session.

## What you get

After running the bootstrap on a clean device you have:

- `claude` on `$PATH` — runs natively under glibc-runner on Android aarch64.
- Code Conductor cloned to `~/cc-projects/code-conductor`, deps installed, server running at <http://127.0.0.1:8787>, configured to use `~/cc-projects/` as its projects root.
- `~/cc-projects/CLAUDE.md` containing the workspace conventions (auto-imported by every project's local `CLAUDE.md` via `@../CLAUDE.md`).
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
| 2 | `scripts/install-cc.sh` | Creates `~/cc-projects/` and drops the vendored `CLAUDE.md` there. `git clone https://github.com/UnmanagedCode/code-conductor.git ~/cc-projects/code-conductor` (or `git pull`). Registers the clone in Code Conductor's central store at `~/cc-projects/.code-conductor/projects/code-conductor/project.json` with `{"group": "CC-Dev"}`. `npm install`, then `PROJECTS_ROOT=~/cc-projects nohup npm start` in the background. Logs to `~/cc-projects/code-conductor/server.log`. Waits up to 10 s for `127.0.0.1:8787` to respond. |
| 3…N | `scripts/install-optional.sh <name>` | **One per project selected via `--with=` or the interactive prompts.** Clone into `~/cc-projects/`, tag `CC-Dev`, `npm install` if it has a `package.json`. Projects with extra system deps delegate to a dedicated installer: `code-share` → `install-code-share.sh` (also `pkg install -y cloudflared`); the harness → `install-playwright.sh` (also `pkg install -y chromium`). See [Optional projects](#optional-projects-cc-install). |
| last | `scripts/register-alias.sh` | Rewrites a managed `# >>> code-conductor aliases >>>` block in `~/.bashrc` with the `cc` dispatcher function, bash completion, and `cc-start`/`cc-stop`/`cc-logs`/`cc-update`/`cc-upgrade`/`cc-install`/`cc-projects` shortcut aliases. |

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

# Tab completion works on the subcommands (and on optional-project names after `install`):
cc <TAB>              # → start  stop  logs  update  upgrade  install  projects
cc install <TAB>      # → code-share  termux-playwright-harness
```

Then browse to <http://127.0.0.1:8787>. The CC UI lists everything under `~/cc-projects/` and groups the bootstrap, Code Conductor, and the harness under **CC-Dev** so they don't clutter your own projects.

CC's own README (full feature list, REST + WebSocket protocol, MCP wiring) lives at <https://github.com/UnmanagedCode/code-conductor/blob/main/README.md>.

## Optional projects (`cc install`)

Add-on projects that aren't part of the core install. `cc install <name>` clones one into `~/cc-projects/`, tags it as the **CC-Dev** group, and `npm install`s its deps if it ships a `package.json`. Re-running just fast-forwards + reinstalls (idempotent). `cc install` with no argument lists what's available and which are already installed.

| Name | What it is |
|---|---|
| `code-share` | [code-share](https://github.com/UnmanagedCode/code-share) — peer-to-peer **read-only** Git repo sharing over LAN/internet. Each party serves repos read-only and pulls from peers; no pushes. Git server on `:9419` (tunnelable via cloudflared), web UI on `:9420` (localhost only). Run it with `node bin/code-share.js serve` from `~/cc-projects/code-share`. |
| `termux-playwright-harness` | The Playwright harness (see below). Aliased as `playwright`/`harness`. Routed through the dedicated installer because it also needs the Termux `chromium` package. |

```bash
cc install                 # list available optional projects + install status
cc install code-share      # clone + npm install code-share
cc install playwright      # alias → termux-playwright-harness (full chromium setup)
```

The registry is the single source of truth in `scripts/lib.sh` (`optional_projects_table`); `cc install`, tab completion, and `update.sh` all read from it, so `cc update` also `git pull`s every installed optional project.

## Optional: Playwright harness

Install it via `cc install playwright`, `bootstrap.sh --with=playwright`, or the interactive prompt — any of which routes to `install-playwright.sh` to set up the [termux-playwright-harness](https://github.com/UnmanagedCode/termux-playwright-harness) — Playwright + Termux Chromium glue for visual UI debugging from a phone. It installs:

- Termux's `x11-repo` (where the `chromium` package lives — not the default `termux-main`), and then the `chromium` package itself (provides `chromium-browser`).
- A clone of the harness at `~/cc-projects/termux-playwright-harness`, tagged as `CC-Dev`.
- Its npm deps (`playwright-core` only — the harness points `executablePath` at the system Chromium, which sidesteps Playwright's normal Chromium auto-download that doesn't ship arm64-Android builds).

The harness is a library, not a server — sibling projects import directly from `~/cc-projects/termux-playwright-harness/browser.mjs`. Nothing starts in the background. `cc update` will `git pull` it too, but only if you've actually installed it.

## Updating

```bash
cc update                   # or: cc-update    or: bash ~/cc-projects/termux-code-conductor/update.sh
cc upgrade                  # or: cc-upgrade   — same as `cc update --cli`
```

`update.sh` does the right thing for every component:

1. `git pull --ff-only` the bootstrap repo, Code Conductor, and every installed optional project (the harness, code-share, …); prints which files changed.
2. Reconciles `~/cc-projects/CLAUDE.md` against the vendored workspace conventions. If you haven't edited it, the new version is dropped in silently. If you *have* edited it AND upstream also changed, you're prompted with **keep / overwrite (backs yours up) / diff**. Baseline tracking lives at `~/.cache/code-conductor-bootstrap/CLAUDE.md.installed`.
3. Re-runs `register-alias.sh` (no-op if `~/.bashrc` is already current).
4. If CC's or any installed optional project's `package.json`/lockfile changed → `npm install` in that dir.
5. If CC code changed and the server is running → graceful restart with `PROJECTS_ROOT=~/cc-projects`.
6. Only re-runs the Claude CLI installer if `scripts/vendor/claude-install.sh` itself changed.

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
# Hand-edit ~/.bashrc and remove the two managed blocks:
#   # >>> claude-code-android (PATH only) >>>  ...  # <<< ... <<<
#   # >>> code-conductor aliases >>>           ...  # <<< ... <<<
```

To also wipe the projects root: `rm -rf ~/cc-projects` — but that'll take everything you've put under there, so check first.

## Known limitations

- **aarch64 only.** No 32-bit ARM, no x86 emulator support. The installer hard-fails on anything else.
- **Localhost-only CC.** Server binds `127.0.0.1:8787` with no auth. Don't `ssh -L` it to a shared box.
- **Background server dies on session end.** Termux kills its process tree when the app is force-stopped. Wrap the server in `tmux` or hold a `termux-wake-lock` if you want it persistent.
- **First install is slow.** The 12-step installer downloads ~50 MB (Node tarball) plus the global npm install. Expect 3–10 minutes on a fresh device depending on network.

## Repo layout

```
.
├── bootstrap.sh            # entrypoint
├── update.sh               # git pull + re-apply (use `cc update`)
├── scripts/
│   ├── lib.sh              # shared logging + Termux guard
│   ├── install-claude-cli.sh
│   ├── install-cc.sh           # clones Code Conductor, sets group, starts server
│   ├── install-optional.sh     # cc install <name>: clone+tag+npm an optional project
│   ├── install-code-share.sh   # optional: clones code-share + pkg install cloudflared
│   ├── install-playwright.sh   # optional: clones termux-playwright-harness (chromium setup)
│   ├── register-alias.sh       # cc dispatcher + completion + cc-* aliases
│   └── vendor/
│       ├── claude-install.sh           # vendored from ~/share/claude-install.sh
│       └── cc-projects-CLAUDE.md       # workspace conventions for ~/cc-projects/
├── .gitignore
├── CLAUDE.md
└── README.md
```

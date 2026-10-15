# Building the Velloc client from source

Most people never need this: install a released client and develop the
[runtime](README.md) against it. Build from source only when you are changing
the platform itself (C++ tools, LLM transport, the bridge).

> **Maintainers only, for now.** Building the client needs repositories that
> are not public yet, so the steps below work only for Velloc maintainers.
> To use Velloc or work on the runtime, install a released client from the
> [Releases page](https://github.com/VellocLabs/velloc-bootstrap/releases/latest).

Windows. Prerequisites: Git, Python 3, Bash (Git Bash or WSL), Visual Studio
build tools, and a lot of disk — a Chromium checkout plus build output; plan
for 100 GB+.

```bash
git clone git@github.com:VellocLabs/velloc-bootstrap.git velloc
cd velloc
./bootstrap.sh              # 1) install depot_tools, then 3) bootstrap & sync
./build.sh                  # pick "Build Debug"
```

The binary lands at `src/out/Debug/chrome.exe`. It defaults to a runtime at
`http://localhost:5173/index.html`, so a `npm run dev` in `nexus_web/` is
picked up with no configuration.

The first build takes hours; every build after that is incremental:

```bash
cd src && autoninja -C out/Debug chrome -j 15     # 1–3 min for a targeted change
```

> **Keep builds incremental.** Never run `gn gen` by hand, clean `src/out/*`,
> or touch `args.gn` — each one forces a multi-hour full rebuild.
> **Judge freshness by `chrome.dll`'s mtime, not `chrome.exe`'s** — the `.exe`
> is a stub and often is not relinked.

## `./bootstrap.sh` menu

| Option | Does |
|---|---|
| 1) Install depot_tools | Clones `depot_tools` into `./depot_tools` if missing. Run this first. |
| 2) Fast sync | Shallow-fetches `custom/main` for `src/` and the default branch for `src/custom_browser`, then a shallow `gclient sync`. Smallest download; no history. |
| 3) Bootstrap & Sync | Clones `src/` and `src/custom_browser` if missing, fixes remotes, resolves branches, then a shallow forced `gclient sync`. **The normal first run.** |
| 4) Bootstrap (force) & Sync | Deletes `src/` and re-clones. Resets a broken workspace. |
| 5) Restore release snapshot | Checks every repo out to the commit recorded in `release_manifest.json`. |

The script reads the `src` URL from `.gclient` and runs
`gclient sync --force --no-history --shallow --revision "src@<revision>"`.
`gclient` always creates `src/` directly under the directory holding
`.gclient`.

Environment overrides: `SRC_URL`, `SRC_BRANCH` (default `custom/main`),
`SRC_REVISION`, `CUSTOM_BROWSER_URL`, `CUSTOM_BROWSER_BRANCH` (default `main`),
`CUSTOM_BROWSER_REVISION`. A missing branch falls back to the remote's default.

CLI equivalents (`scripts/bootstrap_cli.py`): `install-tools`, `fast-sync`,
`bootstrap`, `sync`, `rebootstrap --yes`, `restore` — the last takes
`--manifest <file>`, `--force`, `--no-fetch`; `bootstrap` takes
`--custom-browser-url/-branch/-revision`.

## `./build.sh` menu

One "Build …" entry per file in `args/` (`args/Debug.gn` → "Build Debug", the
default), plus **Build mini_installer** (uses `src/out/Release`, then offers
uninstall / install) and **Reinstall Velloc NSIS**. Add a build config by
dropping another `*.gn` into `args/` — the filename becomes the menu entry.
On Windows PowerShell, `.\build.bat` is the same menu.

If `gn` is missing, `build.sh` runs `gclient runhooks` to fetch it. It also
pre-starts the sccache daemon on purpose: at `-j 15` parallel workers otherwise
race to spawn it and the loser fails its compile step — one reason to build
through the script rather than inventing your own invocation.

## Release snapshots

`release_manifest.json` records every repo's commit for a release.
`./bootstrap.sh` → *Restore release snapshot* (or
`python scripts/bootstrap_cli.py restore`) checks a workspace back to it.

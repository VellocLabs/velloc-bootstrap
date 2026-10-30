# Velloc

**A coding agent that is also a browser, built for Windows.**

Velloc reads and edits your project, runs Bash and PowerShell, and drives real
browser tabs, all inside one desktop application. It works with the major
model providers, local models, and self-hosted endpoints.

**[Download for Windows](https://velloc.app/download/VellocSetup.exe)** ·
[All releases](https://github.com/VellocLabs/velloc-bootstrap/releases/latest)

This repository is the entry point: it publishes the releases and holds the
workspace for building the client. Pick the path that fits what you want to do:

| I want to… | Go to |
|---|---|
| **Use Velloc** | [Quick start](#quick-start) — install, add a key, start a session |
| **Change the agent: loop, tools, prompts, UI** | [Develop the runtime](#develop-the-runtime) — no C++ build needed |
| **Write a plugin or mod** | [Write a mod](#write-a-mod), with [Nebius as a sample](#sample-mod-nebius) |
| **Change the desktop client itself (C++)** | [velloc-core → Build the client](https://github.com/VellocLabs/velloc-core#build-the-velloc-client) |

## Repositories

| Repository | What it is |
|---|---|
| [velloc-bootstrap](https://github.com/VellocLabs/velloc-bootstrap) | This repository. Releases (installer, update feed) and the workspace scripts that check out and build the client. |
| [velloc-runtime](https://github.com/VellocLabs/velloc-runtime) | **The agent.** TypeScript / React: the turn loop, tools as the model sees them, permissions, sessions, memory, skills, plugins, MCP and the whole UI. |
| [velloc-core](https://github.com/VellocLabs/velloc-core) | The client's own C++: the bridge, file / shell / browser capabilities, LLM transport, the installer. Lives at `src/custom_browser/` in a Chromium checkout. |
| [velloc-chromium](https://github.com/VellocLabs/velloc-chromium) | The Chromium fork the client is built on (branch `custom/main`). Upstream code, kept close to Chromium. |
| [plugins-marketplace](https://github.com/VellocLabs/plugins-marketplace) | The built-in marketplace: the plugins and mods every Velloc installs on its own, served from `plugins.velloc.app`. |
| [Nebius-Mod](https://github.com/VellocLabs/Nebius-Mod) | Nebius Token Factory models, cloud sandboxes, a SafeCode session type and web search, as one mod. |
| [mod-template](https://github.com/VellocLabs/mod-template) | The starting point for a new mod shipped through the marketplace. |

## Quick start

1. **Install.** Run
   [VellocSetup.exe](https://velloc.app/download/VellocSetup.exe). Velloc
   updates itself afterwards.
2. **Add a model.** Settings → **Models** → pick a provider, paste its API
   key, choose a model.
3. **Start a session.** Open a project folder and describe the task. The agent
   asks before risky actions; plan mode, allow / deny rules and file snapshots
   let you review and undo what it did.

Your settings, sessions, memory and snapshots live under `~/.velloc/`.

## Develop the runtime

The agent is a web app — **velloc-runtime** — that the installed client loads
from a URL. Point the client at your own dev server and every change to a
`.ts` / `.tsx` file reloads in place. **No C++ build, no Chromium checkout.**

**1 · Run the runtime** (Node.js 22):

```bash
git clone https://github.com/VellocLabs/velloc-runtime.git
cd velloc-runtime
npm install
npm run dev          # http://localhost:5173
```

**2 · Point Velloc at it.** In the installed client: Settings → **About** →
**Runtime source** → `http://localhost:5173` → **Restart now**.

| Runtime source | Loads |
|---|---|
| `http://localhost:5173` | your dev server |
| `https://app.velloc.app` | the hosted stable runtime |
| `https://beta.velloc.app` | the hosted beta runtime |
| *(empty)* | the client's default |

- Only `https://…` and `http://localhost` / `http://127.0.0.1` are accepted.
- An `https` source is pinned to the client's bridge version: the client
  loads `https://app.velloc.app` as `https://app.velloc.app/v2/`, so a hosted
  deploy never changes the contract under an installed client. A localhost
  source is used as is.
- If the runtime fails to load, the panel offers **Restore default runtime** —
  a bad URL is always undoable from the UI.

**3 · Work on it.** `npm run typecheck`, `npm test`. A runtime change never
needs a new client. Architecture, scripts and contributing rules:
[velloc-runtime README](https://github.com/VellocLabs/velloc-runtime#readme).

## Write a mod

A mod is a plugin with code: it hooks the agent's lifecycle and can add a
model provider, MCP servers, session types, panes, status lines and commands.

- Start from [mod-template](https://github.com/VellocLabs/mod-template).
- Try it locally: link the folder as `~/.velloc/plugins/<name>` and restart
  Velloc.
- Ship it through the
  [built-in marketplace](https://github.com/VellocLabs/plugins-marketplace):
  every Velloc picks a new version up within a day.
- [Nebius-Mod](https://github.com/VellocLabs/Nebius-Mod) is a complete
  sample: a provider, an MCP server, a session type and UI panes — see
  [Sample mod: Nebius](#sample-mod-nebius).

## Build the client

Needed only to change the native side — file / shell / browser capabilities,
LLM transport, the bridge, the installer. It is a Chromium build: Windows,
100 GB+ of disk, hours for the first build, minutes after that.

The full guide lives with the code it builds:
**[velloc-core → Build the Velloc client](https://github.com/VellocLabs/velloc-core#build-the-velloc-client)**.
This repository provides the scripts it uses (`bootstrap.sh`, `build.sh`,
`args/`).

## How it fits together

```
velloc-runtime   the agent: loop, tools, sessions, UI      (TypeScript / React)
      ▲
      │  capability bridge: files · shell · browser · model · ui · session
      ▼
Velloc client    the platform: privileged half of each tool (C++, Chromium)
```

The client loads the runtime into an isolated surface and grants it
capabilities over a versioned bridge. The runtime holds no privilege of its
own: a capability the client does not grant does not exist for it. One client
loads any runtime built for its bridge version (`NEXUS_INTERFACE_VERSION`,
currently `2`) — the hosted one, your own deploy, or a local dev server.

## What is in this repository

| Path | Holds |
|---|---|
| `bootstrap.sh` / `.bat` | Installs depot_tools, checks out `src/` and `src/custom_browser/`, syncs |
| `build.sh` / `.bat` | Debug / release builds and the NSIS installer |
| `args/` | The `args.gn` files for each build type |
| `scripts/bootstrap_cli.py` | The CLI behind `bootstrap.sh` |
| `release_manifest.json` | The commit of every repository in the latest release |
| `release_*`, `installer_*` | Release packaging and signing helpers, each with its test |

## Sample mod: Nebius

**[Nebius-Mod](https://github.com/VellocLabs/Nebius-Mod)** shows how far one
mod can extend Velloc. It adds four things:

| Part | What it shows a mod can do |
|---|---|
| **Models** — Nebius Token Factory's open-weight models behind one API key | register a model provider: its credentials, model listing and request mapping |
| **Sandboxes** — commands run in throw-away cloud microVMs, with parallel lanes and a parallel test matrix | bundle an MCP server and fill its secrets without the model ever seeing them |
| **SafeCode** — a session type that edits locally and runs everything in sandboxes | add a session type with its own tools and guards |
| **Web search** — Tavily search tools with a history panel | add panes and panels to a session |

Try it:

1. Settings → **Plugins & Mods** → **nebius** → on.
2. Settings → **Models** → **Nebius Token Factory** → paste a key from
   [tokenfactory.nebius.com](https://tokenfactory.nebius.com/).
3. For sandboxes: install [uv](https://docs.astral.sh/uv/) and enter your
   **Project ID** on the same page. For web search: add a Tavily key there.

Read its source next to [mod-template](https://github.com/VellocLabs/mod-template)
when you write your own. Setup, settings and the tool list:
[Nebius-Mod README](https://github.com/VellocLabs/Nebius-Mod#readme).

## License

Apache License 2.0 — see [LICENSE](LICENSE). © 2026 VellocLabs.

Velloc's own code is under the Apache License 2.0 in every repository. Code
taken from other projects keeps its own licence: the Chromium fork and the
Chromium files in `velloc-core` stay under Chromium's BSD-style licence; other
third-party code is listed in the
[velloc-core README](https://github.com/VellocLabs/velloc-core#license) and in
velloc-runtime's `THIRD_PARTY_NOTICES.md`.

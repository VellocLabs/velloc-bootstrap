# Velloc Code

**Velloc is an open-source code agent harness built on the Chromium
architecture.** The harness — the agent loop, the tool orchestration, the UI —
is a web app called **velloc-runtime**, and it is open source.
It runs on a **client**: a Chromium-based host application that provides the
platform underneath it (filesystem, shell, browser automation, LLM transport).

```
velloc-runtime  ──  the harness         (open source, this is the interesting part)
     ▲
     │  capability bridge
     ▼
velloc client   ──  the runtime platform (Chromium-based host application)
```

The two ship separately and are matched by one number, the **bridge interface
version** (`NEXUS_INTERFACE_VERSION`, currently `2`). One client can load any
runtime build made for its version — a hosted one, your own deploy, or a local
dev server. **That is the whole integration story, and §3 is how you do it.**

---

## 1. Who does what

| | **Runtime** (`nexus_web/` → `velloc-runtime`) | **Client** |
|---|---|---|
| Language | TypeScript / React | C++ (Chromium fork) |
| Ships as | a static web bundle, e.g. `https://app.velloc.app/v2/` | an installer / `chrome.exe` |
| Owns | the agent loop, prompt & context assembly, tool selection, sessions & transcripts, skills, MCP client, memory, permissions UI, the whole UI | filesystem & shell access, browser automation, LLM transport, the bridge, window/panel hosting |
| Runs in | an isolated guest surface — the UI thread, with the agent loop running outside it | the host process + a sandboxed shell utility process |

Everything an agent turn actually *does* — deciding, calling tools, compacting,
persisting — happens in the runtime. The client is the platform that grants it
capabilities and executes the privileged half of each tool call.

## 2. How the runtime plugs into the client

```
┌─ Velloc client (the platform) ──────────────────────────────────────┐
│                                                                     │
│  host surface                                                       │
│    └─ guest surface — velloc-runtime, loaded from the RUNTIME URL   │
│         ├─ UI thread  → React UI                                    │
│         └─ agent loop → runs outside the UI thread                  │
│                │                                                    │
│                │  capability bridge:                                │
│                │  fs · model · ui · session · catalog · browser     │
│                ▼                                                    │
│  capability adapters (C++)                                          │
│    ├─ file tools, SuperEdit, file snapshots                         │
│    ├─ shell service (sandboxed process: Bash, Grep)                 │
│    ├─ web automation (navigate, click, screenshot, …)               │
│    └─ LLM providers (anthropic / openai / google / ollama)          │
└─────────────────────────────────────────────────────────────────────┘
```

Boot, in one line: the client loads the runtime URL into an isolated guest
surface, handshakes with it, and grants it a channel to the capability bridge;
every tool call after that travels over that channel. How the channel is
carried is the platform's business and is expected to change — the runtime
codes against the bridge, not against its transport.

The isolation is the point: the runtime holds no privilege of its own. It has
its own origin, and reaches the platform only through the bridge — so a
capability the client does not grant does not exist for it.

**The runtime cannot run standalone.** Loaded anywhere but a client, it waits
forever for that handshake and never boots.

---

## 3. Run the runtime in a client

The core workflow. Four steps.

### 1 · Get a client

Install one from the
[Releases page](https://github.com/VellocLabs/velloc-bootstrap/releases).
(Building it from source is only needed for platform work — see
[BUILDING.md](BUILDING.md).)

### 2 · Start the runtime

Node 20+.

```bash
git clone git@github.com:VellocLabs/velloc-runtime.git nexus_web
cd nexus_web
npm install                 # postinstall runs patch-package
npm run dev                 # Vite dev server on http://localhost:5173
```

### 3 · Point the client at it

In the client: **Settings → About → Runtime source** → enter the URL →
**Restart now**.

| Value | Loads |
|---|---|
| `http://localhost:5173` | your dev server |
| `http://localhost:5199` | a second checkout's dev server |
| `https://app.velloc.app` | the hosted stable runtime (the default) |
| `https://beta.velloc.app` | the hosted beta runtime |
| *(empty)* | back to the client's built-in default |

A **debug build of the client already defaults to `http://localhost:5173`**, so
in that setup step 3 is nothing at all — just have the dev server up before you
launch it.

### 4 · Use it

Settings → **Models**, add a provider API key, pick a model, point the session
at a project folder. Edit a `.ts`/`.tsx` file and the panel hot-reloads.

### Rules the URL follows

* Only `https://…`, `http://localhost/…` and `http://127.0.0.1/…` are
  accepted; anything else is ignored with a warning.
* An **https** base is pinned to the client's own interface version — the
  client appends `/v<N>/`, so `https://app.velloc.app` is loaded as
  `https://app.velloc.app/v2/`. A base already ending in `/v<digits>/` is left
  alone. This is why a hosted runtime deploy can never change the contract
  under an installed client.
* An **http localhost** base passes through untouched (the dev server serves
  unversioned at `/`) — which is what makes local development work.
* It is stored as the `nexus.webapp_url` profile pref and applies **after a
restart**.

### When it doesn't load

The panel raises a recovery overlay with **Restore default runtime** (clears
the pref, then restarts) and **Try again** — a bad URL is always undoable from
the UI. If the runtime loads but reports a version mismatch, the bundle at that
path was built for a different interface version than the client expects.

---

## 4. Developing the runtime

```bash
npm run dev                 # dev server (hot reload inside the client)
npm run typecheck           # tsc
npm test                    # vitest unit suite
```

**TypeScript-only changes never require anything from the client side** — the
existing binary picks them up on reload.

Serving a production bundle locally instead of the dev server:

```bash
npm run build:versioned     # builds with base = /v<N>/
npm run preview             # point the client at http://localhost:4173/v2/
```

Self-hosting the runtime (Cloudflare, one interface version served at a time):

```bash
npm run deploy              # builds /v<N>/ fresh, stages site/, wrangler deploy
```

**When the contract changes.** Bumping `NEXUS_INTERFACE_VERSION` is required
when the host↔guest contract changes: the `*.api.json` / `*.tool.json`
declarations, the wire types under `src/browser/bridge/protocol/`, the bootstrap
message shape, or a provider wire dialect. Web-only changes that keep the
contract intact do **not** bump it. The number has one source of truth
(`src/custom_browser/VERSION`) and is mirrored into the committed
`nexus_web/src/browser/bridge/protocol/interfaceVersion.gen.ts`; a client build
fails on drift.

---

## 5. Repositories

Four repos, nested on disk. A change touching two of them is two commits in
two repos.

| Path | Remote | Main branch | Holds |
|---|---|---|---|
| `nexus_web/` | `velloc-runtime` | `main` | **the harness — the open-source runtime** |
| `.` | `velloc-bootstrap` | `main` | workspace root: `.gclient`, build args, bootstrap/build scripts |
| `src/` | `velloc-chromium` | **`custom/main`** | the Chromium fork — upstream code, do not edit |
| `src/custom_browser/` | `velloc-core` | `main` | the client's own C++: the bridge, capabilities, native tools, installer |

Working on the runtime alone needs only `velloc-runtime` and a released client.

## 6. Building the client

Only for platform work, and for now only for Velloc maintainers: it needs
repositories that are not public yet. See **[BUILDING.md](BUILDING.md)** — bootstrap, sync,
incremental builds, and the rules that keep a build from turning into a
multi-hour full rebuild.

## 7. Contributing

House rules, in one breath: **develop on a worktree, never on main**; **every
feature and bug fix ships with tests**; **main stays linear** (rebase onto
main, land with `merge --ff-only`); **never hard-code user-visible text** —
every string is a catalog entry, written in English first and translated in the
same change.

User data (settings, sessions, memory, file snapshots) lives under `~/.velloc/`.

## License

MIT — see [LICENSE](LICENSE). © 2026 VellocLabs.

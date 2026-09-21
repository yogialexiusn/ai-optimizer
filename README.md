# AI Optimizer

Reduce token waste and strengthen context focus for AI coding agents with a single setup script.

## Quick start

Run from a **project root** (repo with `.git`; the script can create `docs/` when you choose QMD).

**macOS / Linux / WSL**

```bash
cd /path/to/your-repo
./setup.sh
```

**Windows Command Prompt**

```bat
cd \path\to\your-repo
setup.bat
```

Non-interactive examples (Cursor CLI):

```bash
# Local memory (ICM) + QMD
AGENT=cursor MEMORY_TOOL=icm DOCS_TOOL=qmd bash setup.sh

# Cloud memory (Mem0) + Graphify
AGENT=cursor MEMORY_TOOL=mem0 DOCS_TOOL=graphify MEM0_API_KEY=m0-your-key bash setup.sh
```

```bat
REM Windows Command Prompt
set AGENT=cursor
set MEMORY_TOOL=icm
set DOCS_TOOL=qmd
setup.bat
```

## What gets installed

| Tool | Role | Setup |
|------|------|-------|
| **RTK** | Compress Shell/CLI output before it reaches the agent | Always installed — `rtk init -g --agent cursor` → `~/.cursor/hooks.json` |
| **ICM** *or* **Mem0** | Persistent cross-session memory (pick one) | **ICM**: local SQLite, no account ([rtk-ai/icm](https://github.com/rtk-ai/icm)). **Mem0**: cloud MCP, requires API key ([mem0ai/mem0](https://github.com/mem0ai/mem0)) |
| **QMD** *or* **Graphify** | Project context (pick one) | **QMD**: semantic search over `docs/**/*.md`. **Graphify**: knowledge graph + Cursor MCP (`graphify.serve`) for larger codebases/monorepos |

## Choosing ICM vs Mem0

During setup you pick **one** memory tool:

- **ICM** — simple local memory stored in SQLite on your machine. No account or API key. Best default for most users. Configures MCP + `~/.cursor/rules/icm.mdc`.
- **Mem0** — cloud-hosted memory with semantic search. Requires a free account and API key from [app.mem0.ai](https://app.mem0.ai). Configures MCP + `~/.cursor/rules/mem0.mdc`.
- **None** — skip memory if you only want RTK (+ optional docs tool).

Set non-interactively with `MEMORY_TOOL=icm`, `MEMORY_TOOL=mem0`, or `MEMORY_TOOL=none`.

Back-compat: `ENABLE_ICM=yes|no` or `ENABLE_MEM0=yes|no` map to `MEMORY_TOOL` when `MEMORY_TOOL` is unset.

## Choosing QMD vs Graphify

During setup you pick **one** documentation/codebase tool:

- **QMD** — best when your project knowledge lives in markdown under `docs/`. Registers a collection like `<repo>-docs`, runs `qmd embed`, and installs a `post-commit` hook to keep embeddings fresh.
- **Graphify** — best for larger codebases or monorepos where you need relationship queries across code. Installs `graphifyy` (optional `[mcp]` extra for Cursor `query_graph`), writes `~/.cursor/rules/graphify.mdc`, and installs a `post-commit` hook to rebuild the graph after code commits. Build once with `graphify .` (or `BUILD_GRAPHIFY=yes`).
- **None** — skip both if you only want RTK (+ optional memory).

Set non-interactively with `DOCS_TOOL=qmd`, `DOCS_TOOL=graphify`, or `DOCS_TOOL=none`. For Graphify, `GRAPHIFY_MCP=yes|no` chooses Cursor MCP vs CLI-only.

## How `setup.sh` / `setup.bat` works

1. **RTK** — installs and runs `rtk init` for your agent so command output is compressed before the model sees it.
2. **ICM or Mem0** (optional, mutually exclusive) — configures persistent memory via MCP and writes agent rules.
3. **QMD or Graphify** (optional, mutually exclusive) — indexes project docs or builds a knowledge graph so the agent can retrieve context without reading entire files.
4. **AGENTS.md / GEMINI.md** — appends an "Optimization Utilities" section documenting what was configured.

## Environment variables

| Variable | Values | Description |
|----------|--------|-------------|
| `AGENT` | `cursor`, `github-copilot`, `antigravity` | Target AI agent |
| `MEMORY_TOOL` | `icm`, `mem0`, `none` | Memory backend (local vs cloud) |
| `MEM0_API_KEY` | `m0-...` | Mem0 Platform API key (only when `MEMORY_TOOL=mem0`) |
| `DOCS_TOOL` | `qmd`, `graphify`, `none` | Documentation/codebase context tool |
| `BUILD_GRAPHIFY` | `yes` / `no` | Build `graphify-out/graph.json` during setup (when `DOCS_TOOL=graphify`) |
| `GRAPHIFY_MCP` | `yes` / `no` | Install `graphifyy[mcp]` (Cursor `query_graph`) vs CLI-only `graphifyy` |
| `INSTALL_PYTHON` | `yes` / `no` | Windows: install Python 3.12 via winget when Graphify needs it |
| `AUTO_INSTALL_PREREQS` | `yes` / `no` | Auto-approve system package installs |
| `SKIP_AGENT_CHECK` | `yes` / `no` | Skip agent install verification (e.g. Docker) |

## How the tools affect agent work

**RTK** (token-efficient inputs)

`rtk init -g --agent cursor` configures Cursor-side hooks (`~/.cursor/hooks.json`). Large CLI/Shell outputs are compressed before the model sees them.

**ICM** (local cross-session memory)

When `MEMORY_TOOL=icm`, the script installs ICM, runs `icm init --mode mcp` + `icm init --mode skill`, then **explicitly merges** `icm` into `~/.cursor/mcp.json` (`<abs-path>/icm serve`) so it coexists with Graphify/other MCP servers, and ensures `~/.cursor/rules/icm.mdc`. The agent can `icm_memory_recall` / `icm_memory_store` (or `icm recall` / `icm store`) — no cloud account required.

**Mem0** (cloud cross-session memory)

When `MEMORY_TOOL=mem0`, the script configures the [Mem0 MCP server](https://docs.mem0.ai/integrations/cursor) in `~/.cursor/mcp.json` and adds `~/.cursor/rules/mem0.mdc`. Requires `MEM0_API_KEY`. The agent can `search_memories` / `add_memory` across chats and devices.

**QMD** (markdown docs)

When `DOCS_TOOL=qmd`, the script registers `docs/**/*.md` in a QMD collection, embeds content, and hooks `post-commit` for re-indexing. Prefer `qmd search` / `qmd query` over pasting whole files.

**Graphify** (codebase relationships + MCP)

When `DOCS_TOOL=graphify`, the script installs `graphifyy[mcp]`, runs `graphify hook install` (post-commit graph rebuild), `graphify cursor install`, merges a `graphify` entry into `~/.cursor/mcp.json` (using a Python interpreter with the `[mcp]` extra), and writes Cursor rules. Run `graphify .` once (or set `BUILD_GRAPHIFY=yes`), restart Cursor, then prefer MCP tools (`query_graph`, `get_neighbors`, `shortest_path`) or CLI `graphify query` / `graphify path`.

# Multi-instance setup (WrenAir / WrenVPS / WrenPro)

You can run multiple nanobot instances with separate configs and data. Use a **config path outside the repo** so your instance data survives repo changes.

## Canonical config paths

| Instance  | Config path (example)   | Data dir        |
|----------|-------------------------|------------------|
| WrenAir  | `~/.wrenair/config.json` | `~/.wrenair/`    |
| WrenVPS  | `~/.wrenvps/config.json` | `~/.wrenvps/`    |
| WrenPro  | `~/.wrenpro/config.json` | `~/.wrenpro/`    |

- **Data dir** is derived from the config file location (parent of the config file). All runtime data (cron, logs, media, workspace) lives under that directory when you use `--config`.
- **Cron jobs**: When running via Docker Compose, cron is stored in a dedicated named volume (e.g. `nanobot-cron`, `wrenair-cron`, `wrenvps-cron`) so jobs persist across image rebuilds. Same pattern as `searxng-data` and `hindsight-data`.
- **Workspace** is set in config (`agents.defaults.workspace`), e.g. `~/.wrenair/workspace`, so each instance has its own memory, AGENTS.md, skills, and HEARTBEAT.md.

## Setup

1. Copy the example config for your instance (e.g. `config.wrenair.example.json`) to your chosen path:
   ```bash
   mkdir -p ~/.wrenair
   cp config.wrenair.example.json ~/.wrenair/config.json
   ```
2. Edit `~/.wrenair/config.json`: set workspace path, provider keys, MCP server DB paths (use **absolute paths** for MCP env vars), and optionally `instanceName` (e.g. `"WrenAir"`).
3. Do **not** commit your real config; keep it only in `~/.wrenair` (or your chosen dir).
4. Start the instance with `--config`:
   ```bash
   nanobot gateway --config ~/.wrenair/config.json
   ```

## MCP servers (Todo, Library)

Configure MCP servers under `tools.mcpServers` in your config. Use **absolute paths** for database paths so they work regardless of process cwd.

- **Todo** (Xczer/todo-mcp-server): `npx -y todo-mcp-server`; set `TODO_DB_PATH` in `env` to e.g. `~/.wrenair/todos.db` (expand to absolute in config).
- **Literature / OSINT** (sqlite-literature-management-fastmcp): Python/fastmcp; run from the cloned repo with `uv run` and set `cwd` to the repo path so the server can find its project.

See the example configs in `config.wrenair.example.json` (and `config.wrenvps.example.json`, `config.wrenpro.example.json`) for the exact structure.

---

## Customizing identity and memory

- **AGENTS.md, SOUL.md, USER.md, TOOLS.md**: These bootstrap files live in your workspace (e.g. `~/.wrenair/workspace/`). Replace the template content with your own; the agent loads whatever exists. Use them for core instructions, identity, and tool notes.
- **Core memory**: Long-term facts go in `workspace/memory/MEMORY.md`; the agent and consolidation logic update this. You can also maintain your own markdown files in the workspace and reference them in AGENTS.md.
- **News sources/topics**: Add a file such as `workspace/sources/news-sources.md` or `workspace/topics/news-topics.md` and mention it in AGENTS.md or a small skill so the agent knows to use it for news research and breaking news.

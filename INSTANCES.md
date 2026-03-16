# Multi-instance setup (WrenAir / WrenVPS / WrenPro)

You can run multiple nanobot instances with separate configs and data. Use a **config path outside the repo** so your instance data survives repo changes.

## Canonical config paths

| Instance  | Config path (example)   | Data dir        |
|----------|-------------------------|------------------|
| WrenAir  | `~/.wrenair/config.json` | `~/.wrenair/`    |
| WrenVPS  | `~/.wrenvps/config.json` | `~/.wrenvps/`    |
| WrenPro  | `~/.wrenpro/config.json` | `~/.wrenpro/`    |

- **Data dir** is derived from the config file location (parent of the config file). All runtime data (cron, logs, media, workspace) lives under that directory when you use `--config`.
- **Cron jobs**: By default, cron lives under the instance data dir (for example `~/.wrenair/cron`, `~/.wrenvps/cron`) and is read by the gateway process. Earlier Docker-based workflows used dedicated named volumes (e.g. `nanobot-cron`, `wrenair-cron`, `wrenvps-cron`) so jobs persisted across image rebuilds; for native services, jobs now persist directly on the host.
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

---

## Native services (Ubuntu WrenVPS)

For WrenVPS, run the gateway as a system-wide `systemd` service, while keeping Hindsight in Docker via `docker-compose.wrenvps.yml`.

1. Create a virtualenv and install nanobot:

   ```bash
   cd /opt/nanobot-vps
   python3 -m venv venv
   source venv/bin/activate
   pip install -e /Users/philipclapper/workspace/nanobot
   ```

2. Create `/etc/systemd/system/nanobot-gateway-wrenvps.service`:

   ```ini
   [Unit]
   Description=Nanobot Gateway (WrenVPS)
   After=network.target

   [Service]
   Type=simple
   User=philipclapper
   WorkingDirectory=/opt/nanobot-vps
   EnvironmentFile=/home/philipclapper/.env.wrenvps
   ExecStart=/opt/nanobot-vps/venv/bin/nanobot gateway --config /home/philipclapper/.wrenvps/config.json
   Restart=always
   RestartSec=5

   [Install]
   WantedBy=multi-user.target
   ```

3. Enable and start:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now nanobot-gateway-wrenvps.service
   ```

The gateway now:
- Reads config from `~/.wrenvps/config.json`.
- Uses cron definitions from `~/.wrenvps/cron/`.
- Talks to Hindsight via the Docker service (see `docker-compose.wrenvps.yml`), and to external SearXNG / ntfy according to your config.

---

## Native services (macOS WrenAir)

For WrenAir, run the gateway as a `launchd` user agent.

1. Create a virtualenv and install nanobot:

   ```bash
   cd ~/dev/nanobot-wrenair
   python3 -m venv venv
   source venv/bin/activate
   pip install -e /Users/philipclapper/workspace/nanobot
   ```

2. Create `~/Library/LaunchAgents/ai.nanobot.gateway.wrenair.plist`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>Label</key>
     <string>ai.nanobot.gateway.wrenair</string>
     <key>ProgramArguments</key>
     <array>
       <string>/Users/philipclapper/dev/nanobot-wrenair/venv/bin/nanobot</string>
       <string>gateway</string>
       <string>--config</string>
       <string>/Users/philipclapper/.wrenair/config.json</string>
     </array>
     <key>WorkingDirectory</key>
     <string>/Users/philipclapper/dev/nanobot-wrenair</string>
     <key>EnvironmentVariables</key>
     <dict>
       <key>DOTENV_FILE</key>
       <string>/Users/philipclapper/.env.wrenair</string>
     </dict>
     <key>RunAtLoad</key>
     <true/>
     <key>KeepAlive</key>
     <true/>
     <key>StandardOutPath</key>
     <string>/Users/philipclapper/Library/Logs/nanobot-gateway-wrenair.log</string>
     <key>StandardErrorPath</key>
     <string>/Users/philipclapper/Library/Logs/nanobot-gateway-wrenair.err</string>
   </dict>
   </plist>
   ```

3. Load and start:

   ```bash
   launchctl load -w ~/Library/LaunchAgents/ai.nanobot.gateway.wrenair.plist
   ```

The gateway now:
- Reads config from `~/.wrenair/config.json`.
- Uses cron definitions from `~/.wrenair/cron/`.
- Can talk either to local Hindsight (via `docker-compose.wrenair.yml`) or to the VPS Hindsight endpoint, and to external SearXNG / ntfy services.

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

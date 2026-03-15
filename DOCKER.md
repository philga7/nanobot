# Docker: one-command stand up / tear down

Use Docker Compose to run the nanobot gateway and SearXNG together.

## Stand up

```bash
docker compose up -d
```

This starts:

- **nanobot-gateway** on port 18790 (config and data from `~/.nanobot` on the host).
- **searxng** on port 8080 (web search; no API key).

Create a config at `~/.nanobot/config.json` (or use `nanobot onboard`) and set:

- `tools.web.search.backend`: `"searxng"`
- `tools.web.search.searxngUrl`: `"http://searxng:8080"` (when using this compose; use `http://localhost:8080` if running the gateway on the host and SearXNG in Docker).

## Tear down

```bash
docker compose down
```

To remove SearXNG data as well:

```bash
docker compose down -v
```

## WrenAir (or other instance) in Docker

To run a specific instance (e.g. WrenAir) with its own config and workspace:

1. Create `~/.wrenair/config.json` (see [INSTANCES.md](INSTANCES.md) and `config.wrenair.example.json`).
2. In that config set `tools.web.search.searxngUrl` to `http://searxng:8080`.
3. Start with the override:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.wrenair.yml up -d
   ```

The WrenAir override mounts `~/.wrenair` and runs the gateway with `--config /root/.wrenair/config.json`.

## WrenVPS (SearXNG config on host)

When using the WrenVPS override, SearXNG config is stored on the VPS at **`~/.wrenvps/searxng/`** (e.g. `settings.yml`). Before first run:

```bash
mkdir -p ~/.wrenvps/searxng
```

Copy the repo’s default config (change `secret_key` for production):

```bash
cp searxng/settings.yml ~/.wrenvps/searxng/settings.yml
```

Then start with:

```bash
docker compose -f docker-compose.yml -f docker-compose.wrenvps.yml --env-file .env.wrenvps up -d
```

**Ports:** External access (e.g. `curl` from outside the VPS) uses **8082**. Container-to-container (e.g. nanobot-gateway → SearXNG) uses **searxng_vps:8080**.

## CLI (interactive) with Docker

```bash
docker compose --profile cli run --rm nanobot-cli agent
```

Uses the same image and `~/.nanobot` volume; ensure config exists first.

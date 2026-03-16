# Docker: infra-only stand up / tear down (SearXNG)

Use Docker Compose to run **SearXNG** as an infra dependency, while running the
nanobot gateway natively on the host (see [INSTANCES.md](INSTANCES.md) for WrenAir/WrenVPS).

## Stand up SearXNG

```bash
docker compose up -d
```

When used with the WrenAir/WrenVPS overrides below, this starts a dedicated SearXNG
instance for that host.

Point your instance config (for example `~/.wrenvps/config.json` or `~/.wrenair/config.json`)
at Hindsight via the host or Docker network URL you use in production.

## Tear down

```bash
docker compose down
```

To remove Hindsight data as well:

```bash
docker compose down -v
```

## WrenAir / WrenVPS overrides

To run SearXNG with per-instance data directories, use the overrides:

- **WrenAir**:

  ```bash
  docker compose -f docker-compose.yml -f docker-compose.wrenair.yml up -d
  ```

  This stores SearXNG config under `~/.wrenair/searxng/` on the host. Inside Docker,
  other containers would talk to SearXNG at `http://searxng_wrenair:8080`; when running
  the gateway natively on macOS, use `http://localhost:8083` in your config.

- **WrenVPS**:

  ```bash
  docker compose -f docker-compose.yml -f docker-compose.wrenvps.yml --env-file .env.wrenvps up -d
  ```

  This stores SearXNG config under `~/.wrenvps/searxng/` on the host. Inside Docker,
  other containers would talk to SearXNG at `http://searxng_vps:8080`; when running the
  gateway natively on the VPS, use `http://localhost:8082` in your config.

In both cases, the nanobot gateway itself is expected to run natively (systemd on Ubuntu,
launchd on macOS), and to connect to SearXNG/ntfy services as configured in your
instance `config.json`. Long-term memory is handled via the built-in markdown/SQLite
memory plus any external Mem0 instance you configure separately (see `docs/MEM0.md`).

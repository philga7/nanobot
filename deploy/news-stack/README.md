# External news stack (Docker Compose)

Runnable stack aligned with [docs/NEWS_STACK_EXTERNAL.md](../../docs/NEWS_STACK_EXTERNAL.md):

| Service | Role | Compose profiles |
|---------|------|------------------|
| **qdrant** | Durable vector memory (NOMAD-style) | Always on (no profile) |
| **crucix** | OSINT signal ingestion | `crucix` or `full` |
| **office** | 7/24 Office agent | `office` or `full` |

Compose file lives in this repo as a **reference layout**; you can copy `deploy/news-stack/` into a dedicated infra repo later without changing behavior.

## Requirements

- Docker Engine + Compose **v2.24+** (uses optional `env_file` for Crucix).
- For **Crucix**: vendored repo under `./vendor/crucix` (clone via `scripts/clone-vendors.sh` or manually).
- For **Office**: `./vendor/724-office` as well (same script clones both; you can still bring services up in phases — see below).

## Configuration and secrets (Docker)

Configuration is **split by service** so secrets are not forced into a single file, and so each upstream app keeps its own contract.

| Layer | What it is for | Where it lives | Wired in compose? |
|--------|----------------|----------------|-------------------|
| **Compose project** | Host port numbers (interpolation only) | `.env` next to `docker-compose.yml` (from [`.env.example`](./.env.example)) | Yes — auto-loaded for `${VAR}` in the YAML |
| **Qdrant** | API key and other [Qdrant env](https://qdrant.tech/documentation/guides/configuration/) | Optional [`.env.qdrant`](./.env.qdrant.example) (copy from example; **gitignored**) | Yes — `env_file` with `required: false` |
| **Crucix** | All Crucix runtime keys | `vendor/crucix/.env` (from upstream `.env.example`; **vendor gitignored**) | Yes — `env_file` with `required: false` |
| **7/24 Office** | LLM keys, MCP, memory backends, etc. | Primarily `vendor/724-office/config.json` (from `config.example.json`) | **Build-time copy** in `Dockerfile.office`; optional `vendor/724-office/.env` injected at runtime if the file exists and upstream reads it |
| **Nanobot (host)** | URLs to reach this stack from the gateway | Your instance `config.json` / env / secrets manager | Not part of this compose file |

**Why Office is different:** the image `COPY`s the vendor tree at **build** time, so `config.json` values are frozen in the image unless you (a) rebuild after edits, or (b) **bind-mount** a file over `/app/config.json` at runtime (recommended for production secrets):

```yaml
# Example only — add under `office.volumes` if you use a secrets path on the host:
# - /run/secrets/office-config.json:/app/config.json:ro
```

Use read-only mounts where possible. Keep real `.env` / `.env.qdrant` / `vendor/*` out of git (see [`.gitignore`](./.gitignore)).

Full key tables (Crucix, Office `config.json`, Qdrant) and notes on Bird/SearXNG vs Crucix: [docs/NEWS_STACK_ENV_REFERENCE.md](../../docs/NEWS_STACK_ENV_REFERENCE.md).

## Quick start (Qdrant only)

From this directory:

```bash
cp .env.example .env   # optional; defaults work for ports
# Optional: cp .env.qdrant.example .env.qdrant && edit  # Qdrant API key, etc.
docker compose up -d
```

Published ports bind to **127.0.0.1** on the host. REST API: `http://127.0.0.1:6333` (override with `QDRANT_HTTP_PORT` in `.env`).

### Smoke check (host)

After any `docker compose up`, from this directory:

```bash
./scripts/smoke-stack.sh
```

Uses `curl` against default loopback ports (reads `.env` for port overrides). Unreachable services are reported but do not fail the script.

## Phased bring-up (one service at a time)

Compose is split so you can validate **Docker + config** before Nanobot talks to anything:

1. **Qdrant only** — `docker compose up -d`  
   - Confirms volumes, ports, optional `.env.qdrant` API key.

2. **Add Crucix** — vendor Crucix, then:
   ```bash
   docker compose --profile crucix up -d --build crucix
   ```
   - **Note:** services **without** a profile (qdrant) still start with any `docker compose up` in this project. So this command starts **qdrant + crucix**. That is usually what you want for disk/memory; if you truly need a Crucix-only experiment without qdrant, use a separate compose file or `docker compose run` against a Crucix-only override.

3. **Add Office** — vendor 724-office, configure `config.json`, then:
   ```bash
   docker compose --profile office up -d --build office
   ```
   - Starts **qdrant + office** (office waits for qdrant healthy). Crucix stays off unless you also pass `--profile crucix` or use `full`.

4. **Integrate Nanobot** — after each endpoint responds in `smoke-stack.sh`, point Nanobot at the same URLs. Optional `news_stack` block in Nanobot `config.json` (see [docs/NEWS_STACK_EXTERNAL.md](../../docs/NEWS_STACK_EXTERNAL.md#phased-rollout-deploy-then-nanobot)) holds base URLs for when HTTP clients land; empty values mean “not wired yet.”

## Full stack (Crucix + Office + Qdrant)

```bash
chmod +x scripts/clone-vendors.sh
./scripts/clone-vendors.sh
cp vendor/crucix/.env.example vendor/crucix/.env
# Edit vendor/crucix/.env — API keys, Telegram/Discord, etc. (see Crucix README)

cp vendor/724-office/config.example.json vendor/724-office/config.json
# Edit vendor/724-office/config.json — LLM keys, port 8080, optional MCP

docker compose --profile full up -d --build
```

Same as enabling both optional profiles: `--profile crucix --profile office`.

### Service endpoints (defaults)

All services publish to **loopback** on the host (`127.0.0.1`). Containers still talk to each other by service name on the `news-stack` network (e.g. `http://qdrant:6333`).

- Qdrant: `http://127.0.0.1:6333`
- Crucix: `http://127.0.0.1:3117` (health: `/api/health`)
- 7/24 Office: `http://127.0.0.1:8082` → container `8080` (see upstream README for routes; compose healthcheck uses `GET /health`)

### Startup order

- **Qdrant** starts first; **office** waits until Qdrant passes its healthcheck.
- **Crucix** is independent of Qdrant (signals may flow to nanobot / Office separately).

### 7/24 Office image

`Dockerfile.office` copies `vendor/724-office` into a slim Python image and installs **curl** for image/compose healthchecks (`GET /health` on container port 8080). Upstream defaults to **LanceDB** for its own three-layer memory; wiring **Qdrant** as the long-term store is a separate config step in `config.json` / your NOMAD-style integration.

## Nanobot configuration (conceptual)

Point nanobot (or an MCP bridge) at:

- Crucix HTTP/SSE as **signal source**
- Office HTTP as **decision / tool runtime** (when you expose it)
- Qdrant at `http://<host>:6333` for **memory upsert/search**

The Nanobot config schema includes an optional top-level **`news_stack`** object with camelCase fields (`crucixBaseUrl`, `officeBaseUrl`, `qdrantUrl`, `qdrantApiKey`) — all optional strings, default empty. Fill these as you complete each integration step; the HTTP bridge can read them when implemented. See [NEWS_STACK_EXTERNAL.md](../../docs/NEWS_STACK_EXTERNAL.md#phased-rollout-deploy-then-nanobot).

## Troubleshooting

- **`env_file` required** errors: upgrade Docker Compose to v2.24+, or create an empty `vendor/crucix/.env`.
- **Office build fails**: ensure `vendor/724-office` exists and `docker compose` is run from **`deploy/news-stack`** (build context is `.`).
- **Crucix build fails**: confirm Node 22 expectations are satisfied inside upstream `Dockerfile` (already `node:22-alpine`).

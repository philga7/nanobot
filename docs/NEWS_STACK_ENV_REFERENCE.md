# News stack: configuration and secrets reference

This document summarizes **which keys each Dockerized service expects** and **which file** to use. It is a convenience map; **upstream templates win** when they drift:

- 7/24 Office: [`config.example.json`](https://github.com/wangziqi06/724-office/blob/master/config.example.json) and [README — Configuration](https://github.com/wangziqi06/724-office/blob/master/README.md)
- Qdrant: [Configuration](https://qdrant.tech/documentation/guides/configuration/) and [Security / API keys](https://qdrant.tech/documentation/guides/security/)

Docker wiring (paths, `env_file`, bind mounts) lives in [`deploy/news-stack/README.md`](../deploy/news-stack/README.md) and [`deploy/news-stack/docker-compose.yml`](../deploy/news-stack/docker-compose.yml).

---

## Where each service reads config

| Service | What you edit (in `deploy/news-stack/` after vendoring) | How Compose supplies it |
|--------|----------------------------------------------------------|-------------------------|
| **Qdrant** | `.env.qdrant` (see `.env.qdrant.example`) | `env_file` on the `qdrant` service |
| **7/24 Office** | `vendor/724-office/config.json` (from `config.example.json`) | Copied into the image at **build**; for production secrets prefer a **bind mount** over `/app/config.json` (see deploy README). Optional `vendor/724-office/.env` is loaded only if present and only useful if upstream reads those variables (JSON is primary). |

The compose project `.env` (from `.env.example`) is for **host port interpolation** (`QDRANT_*`, `OFFICE_PORT`), not the full secret surface.

---

## Qdrant

**File:** `deploy/news-stack/.env.qdrant`

| Variable | Role |
|----------|------|
| `QDRANT__SERVICE__API_KEY` | If set, clients must send the `api-key` header on REST/gRPC. |
| Other `QDRANT__…` vars | Optional; see [Qdrant configuration](https://qdrant.tech/documentation/guides/configuration/) (`__` = nested config path). |

---

## 7/24 Office

**File:** `vendor/724-office/config.json` (schema from upstream [`config.example.json`](https://github.com/wangziqi06/724-office/blob/master/config.example.json))

| Section / keys | Role |
|----------------|------|
| `models.default`, `models.providers.*` | Per-provider `api_base`, `api_key`, `model`, `max_tokens` |
| `messaging.token`, `guid`, `api_url` | Messaging platform integration |
| `owner_ids` | Allowed owners |
| `workspace`, `port`, `debounce_seconds` | Runtime paths and HTTP server |
| `memory.*` | Memory pipeline; `embedding_api` (`api_base`, `api_key`, `model`, `dimension`), `retrieve_top_k`, `similarity_threshold` |
| `asr.*` | Speech-to-text credentials |
| `video_api.*` | Video API |
| `tavily_api_key`, `search_api_key` | Built-in search tools |
| `mcp_servers.<name>.env` | **Per-process environment for MCP servers** (use for CLI/API keys for tools you attach here) |

Wiring **Qdrant** as Office's durable vector store is a separate integration step (not shown in the stock `config.example.json`); expect additional keys or MCP config when you implement it.

---

## OSINT API Keys

OSINT data source API keys are managed by the `osint` skill. Set them as environment variables:

| Variable | Role |
|----------|------|
| `OSINT_FRED_API_KEY` | Federal Reserve Economic Data |
| `OSINT_FIRMS_MAP_KEY` | NASA FIRMS |
| `OSINT_EIA_API_KEY` | US EIA |
| `OSINT_AISSTREAM_API_KEY` | Maritime AIS |
| `OSINT_ACLED_EMAIL`, `OSINT_ACLED_PASSWORD` | ACLED conflict API |
| `OSINT_CLOUDFLARE_API_TOKEN` | Cloudflare Radar |

See `nanobot/skills/osint/SKILL.md` for the full source list.

---

## Nanobot (host gateway): not the compose bundle

Nanobot's `config.json` may include an optional top-level **`news_stack`** object. Nested fields use the same camelCase style as the rest of config: `officeBaseUrl`, `qdrantUrl`, `qdrantApiKey` — all optional strings, default empty. HTTP clients can read these when implemented.

URLs for SearXNG and **bird-api** stay in Nanobot's existing **web search** / **compose** config, not in the news stack. This file focuses on the services in `deploy/news-stack/`.

# News stack: configuration and secrets reference

This document summarizes **which keys each Dockerized service expects** and **which file** to use. It is a convenience map; **upstream templates win** when they drift:

- Crucix: [`.env.example`](https://github.com/calesthio/Crucix/blob/master/.env.example) and [README — API Keys Setup](https://github.com/calesthio/Crucix/blob/master/README.md)
- 7/24 Office: [`config.example.json`](https://github.com/wangziqi06/724-office/blob/master/config.example.json) and [README — Configuration](https://github.com/wangziqi06/724-office/blob/master/README.md)
- Qdrant: [Configuration](https://qdrant.tech/documentation/guides/configuration/) and [Security / API keys](https://qdrant.tech/documentation/guides/security/)

Docker wiring (paths, `env_file`, bind mounts) lives in [`deploy/news-stack/README.md`](../deploy/news-stack/README.md) and [`deploy/news-stack/docker-compose.yml`](../deploy/news-stack/docker-compose.yml).

---

## Where each service reads config

| Service | What you edit (in `deploy/news-stack/` after vendoring) | How Compose supplies it |
|--------|----------------------------------------------------------|-------------------------|
| **Qdrant** | `.env.qdrant` (see `.env.qdrant.example`) | `env_file` on the `qdrant` service |
| **Crucix** | `vendor/crucix/.env` (from upstream `.env.example`) | `env_file` on the `crucix` service |
| **7/24 Office** | `vendor/724-office/config.json` (from `config.example.json`) | Copied into the image at **build**; for production secrets prefer a **bind mount** over `/app/config.json` (see deploy README). Optional `vendor/724-office/.env` is loaded only if present and only useful if upstream reads those variables (JSON is primary). |

The compose project `.env` (from `.env.example`) is for **host port interpolation** (`QDRANT_*`, `OFFICE_PORT`, `CRUCIX_PORT`), not the full secret surface.

---

## Qdrant

**File:** `deploy/news-stack/.env.qdrant`

| Variable | Role |
|----------|------|
| `QDRANT__SERVICE__API_KEY` | If set, clients must send the `api-key` header on REST/gRPC. |
| Other `QDRANT__…` vars | Optional; see [Qdrant configuration](https://qdrant.tech/documentation/guides/configuration/) (`__` = nested config path). |

---

## Crucix

**File:** `deploy/news-stack/vendor/crucix/.env`

Upstream loads a repo-root `.env` when running from disk; in Docker, Compose `env_file` injects the same names into `process.env` for [`crucix.config.mjs`](https://github.com/calesthio/Crucix/blob/master/crucix.config.mjs) and `apis/sources/*`.

### OSINT / data sources

| Variable | Role |
|----------|------|
| `FRED_API_KEY` | Federal Reserve Economic Data |
| `FIRMS_MAP_KEY` | NASA FIRMS |
| `EIA_API_KEY` | US EIA |
| `AISSTREAM_API_KEY` | Maritime AIS (`ships.mjs`) |
| `ACLED_EMAIL`, `ACLED_PASSWORD` | ACLED conflict API |
| `CLOUDFLARE_API_TOKEN` | Cloudflare Radar |
| `ADSB_API_KEY` | ADS-B Exchange via RapidAPI |
| `RAPIDAPI_KEY` | Alternative name used in code if `ADSB_API_KEY` is unset |
| `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET` | Reddit OAuth (documented in source; may be missing from `.env.example`) |

### Server and LLM

| Variable | Role |
|----------|------|
| `PORT` | HTTP port inside the container (align with the image default if you change it) |
| `REFRESH_INTERVAL_MINUTES` | Sweep cadence |
| `LLM_PROVIDER` | e.g. `anthropic`, `openai`, `gemini`, `openrouter`, `ollama`, … |
| `LLM_API_KEY` | Provider key (not used for `codex` per upstream) |
| `LLM_MODEL` | Optional override |
| `OLLAMA_BASE_URL` | Ollama base URL; in Docker often `http://host.docker.internal:11434` |

### Telegram and Discord

| Variable | Role |
|----------|------|
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Bot + alerts |
| `TELEGRAM_CHANNELS` | Optional extra channel IDs (comma-separated) |
| `TELEGRAM_POLL_INTERVAL` | Bot polling interval (ms), default `5000` |
| `DISCORD_BOT_TOKEN`, `DISCORD_CHANNEL_ID` | Full Discord bot |
| `DISCORD_GUILD_ID` | Optional; faster slash command registration |
| `DISCORD_WEBHOOK_URL` | Optional; webhook-only alerts |

If `.env.example` and the README disagree, prefer the **README** for Discord/Telegram options.

### Bird, X/Twitter, SearXNG, Alpaca

- **Crucix upstream does not use nanobot’s `bird-api` or SearXNG`**; its feeds are separate (GDELT, OpenSky, Telegram scraping, Reddit, etc.).
- **`/portfolio` in Crucix** is currently a **placeholder** (mentions Alpaca MCP / dashboard), not a set of `ALPACA_*` env vars in the server.
- **X-style and SearXNG usage** for your deployment: configure **nanobot** (e.g. `docker-compose.wrenvps.yml`, instance `config.json`, `.env.wrenvps`) and/or **7/24 Office** (`tavily_api_key`, `search_api_key`, or MCP `env` blocks in `config.json`).

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

Wiring **Qdrant** as Office’s durable vector store is a separate integration step (not shown in the stock `config.example.json`); expect additional keys or MCP config when you implement it.

---

## Nanobot (host gateway): not the compose bundle

Nanobot’s `config.json` may include an optional top-level **`news_stack`** object. Nested fields use the same camelCase style as the rest of config: `crucixBaseUrl`, `officeBaseUrl`, `qdrantUrl`, `qdrantApiKey` — all optional strings, default empty. HTTP clients can read these when implemented.

URLs for SearXNG and **bird-api** stay in Nanobot’s existing **web search** / **compose** config, not in Crucix. This file focuses on the **three services** in `deploy/news-stack/`.

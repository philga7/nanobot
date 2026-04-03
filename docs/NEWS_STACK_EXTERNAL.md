# External News Stack Integration

This repository no longer ships a native in-process news pipeline.

News intelligence is externalized into a dedicated stack:

- Crucix: OSINT signal ingestion
- 7/24 Office: reasoning and action planning
- Qdrant: durable vector memory

Nanobot remains the channel-facing gateway and orchestration boundary.

## Nanobot-Side Contract Models

Contract models are defined in:

- `nanobot/integrations/news_stack/contracts.py`

Primary request/response boundaries:

- `IngestSignalRequest`: normalized Crucix signal ingestion
- `DecideAndActRequest` / `DecideAndActResponse`: gateway-to-agent execution contract
- `MemoryUpsertRequest` / `MemorySearchRequest` / `MemorySearchResponse`: Qdrant memory boundary

## Recommended Deployment Boundary

- Keep service orchestration in a separate deployment repo (or use the reference Compose bundle in-repo).
- Keep nanobot core and interface contracts in this repo.

### Reference Compose bundle

A working **Qdrant**-first stack and optional **Crucix** + **7/24 Office** builds live under:

- [`deploy/news-stack/`](../deploy/news-stack/README.md)

See that README for `docker compose up` and `docker compose --profile full` instructions.

**Secrets and env:** Compose only interpolates **ports** from the project `.env`. Per-service settings use optional `env_file` entries (Qdrant `.env.qdrant`, Crucix `vendor/crucix/.env`), while 7/24 Office is mainly **`config.json`** in the vendor tree (often bind-mounted at runtime so keys are not only baked into the image). See [Configuration and secrets (Docker)](../deploy/news-stack/README.md#configuration-and-secrets-docker) in the deploy README. For a consolidated key list and Bird/SearXNG boundaries, see [News stack env reference](./NEWS_STACK_ENV_REFERENCE.md).

## Phased rollout: deploy, then Nanobot

Recommended order:

1. Bring up **Qdrant**, then **Crucix**, then **Office** using separate Compose profiles (`crucix` / `office` / `full`) — see [deploy/news-stack/README.md](../deploy/news-stack/README.md#phased-bring-up-one-service-at-a-time).
2. Run `./scripts/smoke-stack.sh` from `deploy/news-stack/` to confirm loopback HTTP health before touching Nanobot.
3. Add optional top-level **`news_stack`** to Nanobot `config.json` as you wire each integration (nested keys use the usual camelCase aliases: `crucixBaseUrl`, `officeBaseUrl`, `qdrantUrl`, `qdrantApiKey`). Empty strings mean “not configured”; Nanobot does not require them to start.

There is no production HTTP client in this repo yet that calls those URLs; contracts and API metadata exist first so you can validate the stack and config shape in isolation.

## Suggested Runtime Wiring

```text
Crucix -> nanobot gateway -> 7/24 Office -> Qdrant
                             |
                             +-> action outputs -> Telegram/Slack/ntfy
```

## OpenAI-compatible API path (`/v1/chat/completions`)

HTTP API requests use `channel="api"` in `AgentLoop.process_direct`. Each call includes
`InboundMessage.metadata["news_stack_decide_context"]`: a JSON-serialized
`DecideAndActContext` built by `build_api_path_process_direct_metadata` in
`nanobot/integrations/news_stack/api_context.py`.

Optional header `X-Request-Id` (or `X-Request-ID`) is copied into that context as
`metadata.http_request_id` for tracing and external bridge correlation.

## Notes

- Prefer Qdrant as the long-term memory source of record.
- Treat any local LanceDB state as optional and non-authoritative during transition.

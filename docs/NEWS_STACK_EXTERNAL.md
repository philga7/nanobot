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

- Keep service orchestration in a separate deployment repo.
- Keep nanobot core and interface contracts in this repo.

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

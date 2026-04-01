---
name: ai-newsroom-json-config-pipeline
overview: Design a JSON-driven, multi-domain (news, weather, metals) pipeline on top of the Four-Part AI Newsroom, with scoring, OSINT tagging, and notification flows to Slack and ntfy.
todos: []
isProject: false
---

> [!WARNING]
> Archived design document. This plan is superseded by the external stack integration
> approach documented in `docs/NEWS_STACK_EXTERNAL.md` and the active migration plan.

## High-Level Architecture

- **Core idea**: Keep the existing four-part AI Newsroom architecture (news-pipeline-mcp, library-mcp, journaling-mcp, todo-md-mcp) and extend it with **JSON-based config/state artifacts** for news, weather, and precious metals, plus an **OSINT-oriented scoring/tagging layer** that feeds Slack and ntfy.
- **JSON as truth**: All operational settings live in JSON: sources, topics, schedules, dedupe/history pointers, output channels, scoring thresholds, and templates. MCPs and NanoBot agents *read* these JSON files; only history/dedup and journals mutate over time.
- **Domains**: Implement three parallel but structurally similar domains:
  - **News** (CFP + X/Twitter + SearXNG OSINT)
  - **Weather** (NWS, models, commentary via SearXNG)
  - **Metals** (gold/silver/others via `gold-api.com` plus optional related OSINT)


### 1. JSON Artifact Design

- **Global layout**
  - **Config directory**: `~/.openclaw/cron/` (or similar) continues to hold cron-like job definitions, but we introduce **per-domain JSON files** under `~/.openclaw/config/` (news, weather, metals) and **history/dedupe state** under `~/.openclaw/state/`.
  - **Reference** existing `jobs.json` model from `revamped_ai_newsroom` to keep deliveryPolicy consistent.

- **News config JSON** (example files and roles)
  - `news_sources.json` — list of feeds and commentators:
    - Fields: `id`, `type` (`cfp`, `x`, `rss`, `search`), `url` or `handle`, `priority`, `tags` (e.g. `georgia`, `markets`, `elections`), `enabled`.
  - `news_topics.json` — priority topics + keywords:
    - Fields: `topicId`, `name`, `keywords`, `excludedKeywords`, `regions`, `tags`, `baseScoreBoost`.
  - `news_scoring.json` — scoring DSL-like weights:
    - Fields: weights for `breaking`, `live`, source priority, topic match, recency, OSINT corroboration count, market/geo impact, etc.
  - `news_delivery_templates.json` — Slack/ntfy formatting templates:
    - Fields: per-job templates for headline lines, bullet structure, and whether to include OSINT tags, model names, etc.
  - `news_schedule.json` — human-readable job schedules + quiet windows (refining `jobs.json`):
    - Fields per job: `id`, `type`, `scheduleCron`, `quietWindows`, `maxItems`, `deliveryPolicyId`.

- **News state JSON**
  - `news_history.json` (already described) remains the dedupe store, keyed by URL+topic and tracking last-seen timestamps and scores.
  - Optional `news_story_clusters.json` for dedupes across multiple channels (story-level IDs with member URLs).

- **Weather config JSON**
  - `weather_locations.json` — locations and severe-monitor vs. weekly-outlook roles:
    - Fields: `id` (e.g. `jefferson_ga`), `name`, `lat`, `lon`, `nwsZones`, `roles` (e.g. `severe_monitor`, `weekly_outlook`), `tags`.
  - `weather_sources.json` — NanoBot-specific sources:
    - Fields: `id`, `type` (`nws`, `meteorologist`, `model`), `identifier` (e.g. NWS office, SearXNG query template, model codes `GFS`, `ECMWF`, `ICON`, `UKMET`), `credibilityScore`.
  - `weather_scoring.json` — severity thresholds:
    - Fields: thresholds and points for `tornadoWarning`, `svrTstormWarning`, `flashFloodWarning`, `windGust`, `hailSize`, `modelConsensus`, `trendStrength`.
  - `weather_delivery_templates.json` — Slack/ntfy message structures:
    - Different templates for **severe monitor** vs **weekly outlook**.
  - `weather_schedule.json` — two primary jobs:
    - `severe-monitor`: roughly every 15–30 minutes or your old `~2 hours` schedule, with NTFS + Slack.
    - `weekly-outlook`: weekly schedule (Sunday 12:30 ET), Slack-only.

- **Weather state JSON**
  - `weather_history.json` — dedupe of warning events and major forecast changes.
  - Optional `weather_model_trends.json` — storing last few runs of each model for a location to derive “trend” OSINT.

- **Metals config JSON**
  - `metals_assets.json` — which tickers:
    - Fields: `symbol` (`XAU`, `XAG`, `XPT`, `XPD`, `HG`, `BTC`, `ETH`), `name`, `
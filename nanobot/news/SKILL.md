---
name: news
description: OSINT-driven breaking news pipeline with senior analyst analysis. Scheduled via cron.
metadata: {"nanobot":{"emoji":"📰","requires":{"tools":["web_search","web_fetch"]}}}
---

# News Skill

OSINT-driven breaking news pipeline with senior analyst analysis. Scheduled via cron — no on-demand queries.

---

## Usage

```bash
# Scheduled (cron-triggered) — fetches, scores, enriches, delivers
nanobot news --scheduled --deliver

# On-demand deep analysis of a single story
nanobot news --analyze https://example.com/story
nanobot news --analyze "Story title or description"
```

---

## How It Works

1. **Fetch** — CFP, SearXNG, RSS sources via `services/news_pipeline/`
2. **Score** — Topic relevance, breaking flags, recency
3. **Dedupe** — 7-day history in `NEWS_PIPELINE_DIR/history/`
4. **Enrich** — Senior analyst OSINT for score ≥ 7 (entity extraction via LLM)
5. **Deliver** — Slack `#breaking-news` + ntfy `wrenvps-notifications` (score ≥ 10)

---

## Cron Setup

```bash
# Every 15 min, 6am–11pm ET
*/15 6-23 * * * nanobot news --scheduled --deliver
```

---

## Config

| Setting | Value |
|---------|-------|
| Slack channel | `#breaking-news` |
| ntfy topic | `wrenvps-notifications` |
| ntfy threshold | Score ≥ 10 |
| Enrichment threshold | Score ≥ 7 |
| Dedup TTL | 7 days |
| Max items per run | 10 |

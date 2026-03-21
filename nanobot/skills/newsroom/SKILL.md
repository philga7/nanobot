---
name: newsroom
description: JSON-driven news pipeline for breaking news, weather, and markets. Runs standalone via cron or NanoBot skill.
metadata: {"nanobot":{"emoji":"📰","requires":{"tools":["web_search","web_fetch"]}}}
---

# Newsroom Skill

Two pipelines are available: the standalone `services/news_pipeline/` (independent of NanoBot) and the NanoBot-native `nanobot/news/` skill (integrated, scheduled).

For NanoBot-native breaking news with OSINT analysis, use `nanobot/news/`:
- Cron-scheduled: `*/15 6-23 * * *`
- LLM entity extraction + senior analyst persona for scores ≥ 7
- Delivery: Slack `#breaking-news` + ntfy `wrenvps-notifications` (score ≥ 10)
- On-demand deep analysis: `nanobot news --analyze <url>`

---

## How It Works

1. **Fetch** — RSS, X/Twitter (bird-api), SearXNG, NWS, Gold API.
2. **Score** — Topic relevance, recency, OSINT tags, breaking flags.
3. **Dedupe** — History files in `history/` prevent repeats (7-day TTL).
4. **Deliver** — `--deliver` posts directly to Slack and ntfy.

---

## Setup

Copy config from the repo:

```bash
mkdir -p ~/.wrenvps/news-pipeline/history
cp services/news_pipeline/examples/*.json ~/.wrenvps/news-pipeline/
```

Edit JSON as needed. Override config dir: `export NEWS_PIPELINE_DIR=/path/to/config`

---

## Running

**Scheduled (recommended):** Add to crontab or systemd timer:

```bash
# Every 15 min during daytime (breaking news)
*/15 6-23 * * * cd /path/to/nanobot && NEWS_PIPELINE_DIR=~/.wrenvps/news-pipeline .venv/bin/python -m services.news_pipeline --deliver

# Georgia desk every 2 hours
0 */2 * * * cd /path/to/nanobot && NEWS_PIPELINE_DIR=~/.wrenvps/news-pipeline .venv/bin/python -m services.news_pipeline --job georgia-news-desk --deliver
```

**Manual:**

```bash
# Dry run (no history writes, no delivery)
python -m services.news_pipeline --dry-run

# Full run + delivery
python -m services.news_pipeline --deliver

# Single desk or job
python -m services.news_pipeline --desk news --deliver
python -m services.news_pipeline --job breaking-news-desk --deliver
```

---

## Config Files

| File | Purpose |
|------|---------|
| `jobs.news.json` | Georgia desk, breaking desk — sources, scoring, routing |
| `jobs.weather.json` | Severe monitor, weekly outlook — NWS locations |
| `jobs.markets.json` | Metals (XAU, XAG, BTC, ETH) — Gold API, alert rules |
| `scoring.json` | Thresholds, OSINT keyword map, routing, templates |
| `topics.json` | Preferred topics (weighted), ignored topics |
| `history/` | Dedupe: `news_history.json`, `weather_history.json`, `markets_history.json` |

---

## Delivery

Set env vars:
- `SLACK_BOT_TOKEN` — Slack bot token for posting
- `NTFY_URL` — ntfy server (e.g. `https://ntfy.example.com`)
- `NTFY_TOKEN` — optional auth
- `NTFY_TOPIC` — default `news-pipeline`

Per-source `delivery` in JSON controls Slack channels, ntfy, and templates. `deliveryPolicy.mode`: `autoPost` (pipeline posts) or `returnOnly` (no delivery).

---

## History / Dedupe

Deduplication uses JSON files in `history/`:
- `news_history.json`
- `weather_history.json`
- `markets_history.json`

Items older than 7 days are pruned. No separate memory or journal layer.

---

## Ad-hoc Queries

When the user asks "what's breaking?" or "check the news", use `web_search` and `web_fetch` for one-off queries. The pipeline is for scheduled sweeps, not interactive Q&A.

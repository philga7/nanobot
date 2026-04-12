---
name: ai-ml-newsletter
description: IMAP ingestion of AI/ML newsletters, cross-referenced daily digest, Slack delivery to #ai-ml, OSINT feed export.
metadata: {"nanobot":{"emoji":"🤖","requires":{"bins":["python3"],"optional":["curl"]},"install":[]}}
---

# ai-ml-newsletter

Story-centric newsletter pipeline: poll a shared Hostinger inbox for **AI/ML** senders only, parse issues (starting with **The Neuron**), dedupe and cross-reference coverage across newsletters, maintain an apps/sites catalog, emit an **OSINT feed** JSON, and post a Slack digest to **`#ai-ml`** via `chat.postMessage` (same pattern as the OSINT skill’s `deliver.sh`).

## Overview

1. **`scripts/newsletter-ingest.sh`** — IMAP `UNSEEN`, filter by known AI/ML senders (and subject-keyword fallback), parse stories / notable apps / links, write `cache/raw/{slug}_{date}.json`, mark messages read, track `processed_ids.json`.
2. **`scripts/cross-reference.sh`** — Load today’s raw JSONs (timezone `America/New_York` by default), merge overlapping stories (URLs + headline similarity + entity overlap), write `cache/stories/daily_digest_{date}.json`, update `apps-sites.json`, write `osint_feed.json` and `latest-digest.json`, post to Slack.

## Trigger Phrases

- “AI newsletter digest”
- “What’s new in AI”
- “AI-ML brief”
- “Newsletter roundup”

## Paths

| Purpose | Location |
|--------|----------|
| Skill root (bundled) | `nanobot/skills/ai-ml-newsletter/` |
| Raw cache | `cache/raw/` (override `AI_ML_NEWSLETTER_CACHE_RAW`) |
| Story digest cache | `cache/stories/` (override `AI_ML_NEWSLETTER_CACHE_STORIES`) |
| Runtime state | `~/.wrenvps/ai-ml-newsletter/` |
| IMAP credentials | `~/.wrenvps/ai-ml-newsletter/email_creds.json` |
| Processed Message-IDs | `~/.wrenvps/ai-ml-newsletter/processed_ids.json` |
| Apps catalog | `~/.wrenvps/ai-ml-newsletter/apps-sites.json` |
| Latest digest snapshot | `~/.wrenvps/ai-ml-newsletter/latest-digest.json` |
| OSINT handoff | `~/.wrenvps/ai-ml-newsletter/osint_feed.json` |

Use the **same** `email_creds.json` shape as `dividend-intel` (copy or symlink from `~/.wrenvps/dividend-intel/email_creds.json` if you already have it).

## Ingestion (`newsletter-ingest.sh`)

- Reads `~/.wrenvps/ai-ml-newsletter/email_creds.json` (`host`, `port`, `username`, `password`, `ssl`).
- Searches `UNSEEN` only.
- **Processes** mail if:
  - `From` is in `AI_ML_SENDERS` (extensible list in the script; includes `theneuron@newsletter.theneurondaily.com`, `swyx@ainews.email`), **or**
  - `Subject` matches AI/ML keywords (`AI`, `ML`, `machine learning`, `GPT`, `LLM`, etc.).
- **Blocklist:** `BLOCKED_SENDERS` rejects known finance/marketing domains (substring match on the From address) before other checks — e.g. stockanalysis, marketwatch, seekingalpha, morningbrew.
- **Skips** (leaves unread, no `processed_ids` entry) if the message does not match the above **and** looks dividend/income oriented (shared inbox — avoids fighting `dividend-intel`).
- Prefers `text/plain`; strips HTML with stdlib `html.parser` when needed.
- Per-message JSON is merged into `cache/raw/{newsletter_slug}_{date}.json` (same slug + day → append stories / apps / links).
- IMAP or network failure → log and non-zero exit; single-message parse failure → skip and continue.

## Cross-referencing (`cross-reference.sh`)

- Selects “today” in `AI_ML_NEWSLETTER_TZ` (default `America/New_York`).
- Loads all `cache/raw/*_{date}.json`.
- Clusters stories using:
  - **URL matching** after stripping common tracking query params
  - **Headline similarity** (token Jaccard over normalized words, stdlib only)
  - **Entity overlap** (capitalized tokens in headlines)
- Produces merged objects with `sources[]`, `coverage_count`, combined `summary`, and deduped `links`.
- Updates the append-only **apps/sites** catalog (`times_mentioned`, `first_seen`, `first_seen_in`).
- Writes `osint_feed.json` with per-item `osint_relevance` heuristics (`high` / `medium` / `low`).
- Builds Slack **mrkdwn** (trimmed to ~1500 words): `*bold*`, `_italic_`, `<https://example.com|label>` links for story URLs, source lines, and apps; plain `https://…` in summaries is linkified the same way. Posts when `NANOBOT_CHANNELS__SLACK__BOT_TOKEN` is set.

### Environment

| Variable | Purpose |
|----------|---------|
| `NANOBOT_CHANNELS__SLACK__BOT_TOKEN` | Bot token for `chat.postMessage` |
| `AI_ML_NEWSLETTER_SLACK_CHANNEL` | Channel ID or name (default `#ai-ml`) |
| `AI_ML_NEWSLETTER_SKIP_SLACK` | `1` to skip posting (testing) |
| `AI_ML_NEWSLETTER_TZ` | IANA timezone for “today” |
| `AI_ML_NEWSLETTER_STATE_DIR` | Override `~/.wrenvps/ai-ml-newsletter` |
| `AI_ML_NEWSLETTER_SKILL_ROOT` | Skill root if scripts are copied elsewhere |

## Slack delivery

- Uses Slack Web API `chat.postMessage` with JSON body `{channel, text}` (same approach as `nanobot/skills/osint/deliver.sh`).
- Long digests are split into multiple messages (~3500 characters per chunk).
- Format: header, **TOP STORIES** (source counts, `_See also (Newsletter):_ <url|Newsletter>` lines, per-story `→ <url|type>` link rows), **NOTABLE APPS & SITES** (verbatim description plus `<url|host>` on the next line), **COVERAGE MAP** (bulleted `*headline*` with `_sources_`).

## OSINT integration

- `osint_feed.json` schema:

```json
{
  "date": "2026-04-11",
  "stories": [
    {
      "headline": "...",
      "summary": "...",
      "categories": ["LLM"],
      "links": ["https://..."],
      "coverage_count": 2,
      "osint_relevance": "high"
    }
  ],
  "apps_sites": [
    {
      "name": "...",
      "url": "...",
      "category": "dev_tools",
      "osint_relevance": "medium"
    }
  ]
}
```

- The OSINT skill does **not** need changes; it may read this file when you want AI/ML context in a briefing.

## Apps & sites catalog

- `apps-sites.json` holds running tool/site mentions with dedupe by URL, `times_mentioned`, and provenance fields — separate from the narrative digest.

## Cron schedule

Daily **6:45 AM Eastern** (seven days a week):

```text
45 6 * * * America/New_York
```

Example job message (install scripts under `~/.wrenvps/scripts/` or run from checkout):

```text
bash /path/to/nanobot/skills/ai-ml-newsletter/scripts/newsletter-ingest.sh && bash /path/to/nanobot/skills/ai-ml-newsletter/scripts/cross-reference.sh
```

Use nanobot cron (`shell_exec: true`, `deliver: false`) or systemd timer — same pattern as `dividend-intel` / OSINT.

## Quick test

```bash
cd nanobot/skills/ai-ml-newsletter
export AI_ML_NEWSLETTER_SKIP_SLACK=1
bash scripts/cross-reference.sh
```

With IMAP credentials in place:

```bash
bash scripts/newsletter-ingest.sh
```

Re-run ingest to confirm `processed_ids.json` prevents duplicate processing of the same `Message-ID`.

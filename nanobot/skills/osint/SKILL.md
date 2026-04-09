---
name: osint
description: >-
  OSINT intelligence briefing. Queries 29 open-source intelligence APIs
  (GDELT, FRED, FIRMS, EIA, BLS, CISA, markets, sanctions, conflict, weather,
  maritime, social, NASA missions) plus RSS feeds and Twitter/X signals from the
  intel pipeline, caches results for 15 minutes, and synthesizes a
  leverage-first 9-section briefing with cross-source correlation and narrative
  tracking. Trigger with "brief me", "intel brief", "osint brief", "what's
  going on", "latest intelligence", or "refresh intel".
metadata: {"nanobot":{"emoji":"🔍","requires":{"bins":["curl","jq"]}}}
---

# OSINT Intelligence Briefing

Act as a senior OSINT analyst. Query intelligence sources across three layers
(API, RSS, Twitter/X), cache results, and deliver a leverage-first intelligence
briefing with topic-weighted story prioritization.

## Trigger Phrases

- "brief me"
- "intel brief"
- "osint brief"
- "what's going on"
- "latest intelligence"
- "refresh intel"

## Three-Layer Architecture

The briefing pulls from three parallel data layers:

| Layer | Source | Config |
|-------|--------|--------|
| **API** | 29 scripts in `sources/` | API keys in `~/.wrenvps/osint/.env` |
| **RSS** | 20+ RSS feeds (SCOTUSblog, Times of Israel, CSIS, Brookings, Defense One, War on the Rocks, AJC, GPB, etc.) | `~/.wrenvps/intel/config/sources.json` |
| **Twitter/X** | 11 accounts via bird-api (Mario Nawfal, Chad Pergram, RawsAlerts, Mossad_il, Leading Report, etc.) | `~/.wrenvps/intel/config/sources.json` |

Layer orchestration:
- `brief.sh` calls `~/.wrenvps/intel/sources/fetch-all.sh` (or individual `fetch-rss.sh` / `fetch-twitter.sh`) before synthesis
- RSS cache: `~/.wrenvps/intel/cache/rss/`
- Twitter cache: `~/.wrenvps/intel/cache/twitter/`
- If bird-api is down, Twitter layer returns empty and briefing continues
- If RSS feeds fail, available feeds are used; briefing is never blocked

## Topic Weighting

Priority topics are read from `~/.wrenvps/intel/config/topics.json`:

- Items matching high-weight topics (Iran 1.5, Israel 1.5, ICE 1.3, Tariffs 1.3, DOGE 1.2, etc.) surface higher in sections 1-3
- Items matching `major_event_keywords` get `:rotating_light: BREAKING` urgency tags
- Items are labeled with tier from `source_tier_classification`: **mainstream**, **alternative**, or **fringe**

## Georgia Desk

When RSS items contain Georgia-relevant content (AJC, GPB, keywords: Georgia, Atlanta, Kemp, Warnock), a **GEORGIA DESK** subsection is included in the briefing.

## Sources (29 Total — API Layer)

Sources are queried directly via shell scripts in the `sources/` directory.
Each script returns structured JSON to stdout.

### Core Sources (API key required marked with *)

| # | Source | Script | Category |
|---|--------|--------|----------|
| 1 | GDELT | `gdelt.sh` | Conflict / Geopolitics |
| 2 | FRED* | `fred.sh` | Macro / Economic |
| 3 | NASA FIRMS* | `firms.sh` | Fire / Thermal |
| 4 | EIA* | `eia.sh` | Energy |
| 5 | BLS | `bls.sh` | Jobs / CPI |
| 6 | CISA KEV | `cisa-kev.sh` | Cyber / Vulnerabilities |
| 7 | YFinance | `yfinance.sh` | Markets |
| 8 | OFAC | `ofac.sh` | Sanctions |
| 9 | Cloudflare Radar* | `cloudflare.sh` | Internet / Outages |

### Secondary Sources

| # | Source | Script | Category |
|---|--------|--------|----------|
| 10 | OpenSky | `opensky.sh` | Air traffic |
| 11 | ACLED* | `acled.sh` | Armed conflict |
| 12 | ReliefWeb | `reliefweb.sh` | Humanitarian |
| 13 | WHO | `who.sh` | Disease outbreaks |
| 14 | OpenSanctions | `opensanctions.sh` | Sanctions enrichment |
| 15 | Safecast | `safecast.sh` | Radiation |
| 16 | NOAA | `noaa.sh` | Weather / Severe |
| 17 | EPA | `epa.sh` | Environmental |
| 18 | CelesTrak | `space.sh` | Satellites |
| 19 | Maritime AIS* | `maritime.sh` | Ship tracking |
| 20 | USAspending | `usaspending.sh` | Federal spending |
| 21 | UN Comtrade | `comtrade.sh` | Trade data |
| 22 | NY Fed GSCPI | `gscpi.sh` | Supply chain |
| 23 | US Treasury | `treasury.sh` | US debt/yields |
| 24 | Bluesky | `bluesky.sh` | Social |
| 25 | Reddit | `reddit.sh` | Social |
| 26 | Telegram | `telegram.sh` | Social OSINT |
| 27 | KiwiSDR | `kiwisdr.sh` | HF radio |

| 28 | NASA Missions | `nasa.sh` | Space / Human Spaceflight |

### Patents (bonus)

| 29 | USPTO Patents | `patents.sh` | Tech patents |

## API Keys (Environment Variables)

| Env Variable | Source |
|-------------|--------|
| `OSINT_FRED_API_KEY` | FRED |
| `OSINT_FIRMS_MAP_KEY` | NASA FIRMS |
| `OSINT_EIA_API_KEY` | EIA |
| `OSINT_AISSTREAM_API_KEY` | Maritime AIS |
| `OSINT_ACLED_EMAIL` | ACLED |
| `OSINT_ACLED_PASSWORD` | ACLED |
| `OSINT_CLOUDFLARE_API_TOKEN` | Cloudflare Radar |

Sources without keys degrade gracefully (free-tier or no-auth endpoints).

### ACLED status note

If ACLED returns Cloudflare `530` / error `1016`, treat ACLED as degraded and
continue the briefing without ACLED event content. This is an upstream DNS/origin
issue on the ACLED side, not a client-side parsing failure.

### WrenVPS env setup

Add these to your local `.env.wrenvps` (not committed):

```bash
OSINT_ACLED_EMAIL=your-acled-email@example.com
OSINT_ACLED_PASSWORD=your-acled-api-key
```

ACLED registration: <https://acleddata.com/acess-api/>

## Cache Strategy

**Rule:** No source queried more than once every 15 minutes.

| Layer | Cache dir |
|-------|-----------|
| API | `{skill_dir}/cache/` — each source as `{source}.json` |
| RSS | `~/.wrenvps/intel/cache/rss/` — managed by fetch-rss.sh |
| Twitter | `~/.wrenvps/intel/cache/twitter/` — managed by fetch-twitter.sh |

- Store `fetched_at` ISO timestamp in each cached file
- If `now - fetched_at < 15 min`, use cache
- `--force` flag on any source script bypasses cache

## Running a Briefing

To produce a briefing, run the orchestrator:

```bash
bash /path/to/skills/osint/brief.sh
```

This will:
1. Check all source caches for freshness
2. Fetch stale sources in parallel (15s timeout)
3. Combine cached data into a single JSON payload
4. Output combined intelligence data for synthesis

To refresh all caches without producing a brief:

```bash
bash /path/to/skills/osint/refresh-all.sh
```

## Automated Delivery (Slack + ntfy)

Use `deliver.sh` to post a briefing summary to Slack and ntfy:

```bash
bash /path/to/skills/osint/deliver.sh --force
```

Supported flags:

- `--dry-run` prints the outgoing message without posting
- `--template intelSignal|breakingBullet` chooses briefing style
- `--channel-id C0AGWCQ1ZDE` overrides Slack target channel id

Expected env vars:

- `NANOBOT_CHANNELS__SLACK__BOT_TOKEN`
- `OSINT_BRIEFING_SLACK_CHANNEL_ID` (default `C0AGWCQ1ZDE`)
- `OSINT_BRIEFING_TEMPLATE` (default `intelSignal`)
- `NTFY_URL`, `NTFY_TOPIC`, optional `NTFY_TOKEN`

## Cron Setup (Full Ops)

Install twice-daily OSINT delivery jobs into workspace cron store:

```bash
# preview only
python /path/to/skills/osint/install_cron.py

# apply to workspace cron/jobs.json
python /path/to/skills/osint/install_cron.py --apply
```

Environment overrides:

- `OSINT_BRIEFING_CRON_MORNING` (default `0 7 * * *`)
- `OSINT_BRIEFING_CRON_EVENING` (default `0 18 * * *`)
- `NANOBOT_AGENTS__DEFAULTS__WORKSPACE` (default `~/.wrenvps/workspace`)

## Unified Intel Pipeline

Sourcing is handled by `~/.wrenvps/intel/sources/` — a separate sourcing layer
that fetches API, RSS, and Twitter data into `~/.wrenvps/intel/cache/`.

When synthesizing a brief, read cached data from:
- `~/.wrenvps/intel/cache/api/` — API source data (GDELT, FRED, CISA, etc.)
- `~/.wrenvps/intel/cache/rss/` — RSS feed data (CSIS, Brookings, Defense One, etc.)
- `~/.wrenvps/intel/cache/twitter/` — Twitter data (Mario Nawfal, Chad Pergram, etc.)
- `~/.wrenvps/intel/cache/_all.json` — Combined output from fetch-all.sh

Priority topics and weights: `~/.wrenvps/intel/config/topics.json`
Source registry: `~/.wrenvps/intel/config/sources.json`

To refresh all sources before briefing: `bash ~/.wrenvps/intel/sources/fetch-all.sh`
To refresh a single layer: `bash ~/.wrenvps/intel/sources/fetch-rss.sh` (etc.)

## Source Tier Classification

```
Mainstream: Reuters, AP, BBC, CNN, NYT, WSJ, WaPo, Guardian, ABC, NBC, CBS, Fox News, Chad Pergram
Alternative: Substack, Rumble, BitChute, Telegram channels, Gab, Gettr, Truth Social, Mario Nawfal, RawsAlerts, Leading Report
Fringe: ZeroHedge, Infowars, NaturalNews, Gateway Pundit, Breitbart, Epoch Times, Revolver, Daily Caller, Citizen Free Press
```

## Correlation Topics Watch List

Reference list for Section 9 (agent should identify emerging topics beyond this list):

```
Economy: tariffs, Fed rates, inflation, housing, supply chain, layoffs
Geopolitics: China-Taiwan, Russia-Ukraine, Israel-Gaza, Iran
Finance: crypto regulation, banking stress
Politics: elections, immigration
Tech: AI regulation, deepfakes, antitrust
Security: nuclear threats, cyber incidents
Health: pandemics, outbreaks
Environment: climate events, extreme weather
```

## 9-Section Briefing Framework

When producing a brief, synthesize ALL available source data (API + RSS + Twitter) into this structure.

**Topic weighting rule:** Items from RSS/Twitter matching high-weight topics in `topic_weights`
(Iran ≥1.5, Israel ≥1.5, ICE ≥1.3, Tariffs ≥1.3, DOGE ≥1.2, etc.) must surface in sections
1-3 before lower-weight items. Items matching `major_event_keywords` get `BREAKING` urgency tags.
Label RSS/Twitter items with their tier (mainstream / alternative / fringe) where known.

```
1. LEVERAGEABLE IDEAS
   3-5 specific, actionable opportunities. Each must include:
   - Thesis and instrument/sector
   - Why now (catalyst) — cite RSS/Twitter signals where relevant
   - Time horizon
   - Invalidation condition
   - Confidence: High / Medium / Low
   Priority: items matching high-weight topics go first.

2. EXECUTIVE THESIS
   1-3 most important things happening right now. Strong view, not hedged.
   Draw on RSS headlines and Twitter signals alongside API data.

3. SITUATION AWARENESS
   Top 3-5 developments. What happened, who is involved, why it matters,
   what changes.
   Include BREAKING-tagged items first if any matched major_event_keywords.
   Note any individual dominating the current news cycle (3+ stories).

4. PATTERN RECOGNITION
   Cross-source correlations across all three layers:
   - Conflict + energy + inflation
   - Macro weakness + market stress
   - Sanctions + logistics anomalies
   - Weather + supply chain
   - RSS/Twitter signal convergence on same event = elevated confidence
   - Space: merge NASA mission status (nasa.sh) with CelesTrak orbital data (space.sh) into
     a unified SPACE MISSIONS section — active crewed missions, upcoming launches, notable
     satellite activity

5. HISTORICAL PARALLELS
   What current situation rhymes with. What matched, what differs,
   what happened next.

6. MARKET IMPLICATIONS
   Equities, bonds, commodities, gold, oil, crypto — explicit direction
   calls with reasoning.

7. DECISION BOARD
   - Best long position
   - Best hedge
   - Watchlist items
   - 24-72hr monitoring priorities

8. SOURCE INTEGRITY
   Data quality assessment, gaps in coverage, what relies on soft signals
   vs. hard data, any sources that failed or returned stale data.
   Note which layers were available (API / RSS / Twitter) and any degraded feeds.

9. CROSS-SOURCE CORRELATION
   Stories appearing across multiple independent sources:
   - Same event reported by 3+ sources → high confidence signal
   - Escalation pattern (new details, broader impact) vs. rehash
   - Source divergence (different framing = narrative split)
   - Fringe-to-mainstream crossover (story originating from alternative
     sources now appearing in mainstream outlets)
   - For each correlation: sources involved, what's converging, what differs

   Narrative tracking (within correlation section):
   - Fringe-to-mainstream crossover: flag stories crossing source boundaries
   - Narrative divergence: same event, different framing across source types
   - Disinfo amplification: known disinfo narratives gaining traction
   - Source classification reference: fringe / alternative / mainstream

GEORGIA DESK (append when Georgia-relevant content found)
   Items from AJC, GPB, or matching Georgia/Atlanta/Kemp/Warnock keywords.
   Sourced from RSS layer; include headline, source, and tier label.
```

## Output Format

- Markdown, Telegram-friendly
- No raw data dumps — synthesized judgment only
- Include relevant URLs where available
- Urgency tags: BREAKING, ELEVATED, ROUTINE
- Target ~800 words (Telegram-friendly length)
- Always state the briefing timestamp (UTC)

## Delivery Configuration (Ops Mode)

When automated delivery is enabled, OSINT briefing output should route through
the same Slack + ntfy delivery pattern used by the newsroom pipeline.

Reference config: `delivery.example.json`

- Slack target channel: `#intel-signals` (`C0AGWCQ1ZDE`)
- Cadence (ET): `0 7 * * *` and `0 18 * * *`
- Template style: `intelSignal` (default) or `breakingBullet` for urgent updates
- Secondary channel: ntfy (best-effort)

Create cron jobs only when full ops is ready.

## Testing

1. Run individual source: `bash sources/gdelt.sh` — should return JSON
2. Check cache: `ls cache/` — files appear after fetch
3. Run full brief: `bash brief.sh` — combined intelligence output
4. Run again within 15 min — cache used, no new API calls
5. Force refresh: `bash refresh-all.sh --force`

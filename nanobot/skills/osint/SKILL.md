---
name: osint
description: >-
  OSINT intelligence briefing. Queries 30+ open-source intelligence APIs
  (GDELT, FRED, FIRMS, EIA, BLS, CISA, markets, sanctions, conflict, weather,
  maritime, social, NASA missions, precious metals, multi-model forecasts) plus
  RSS feeds and Twitter/X signals from the intel pipeline, caches results for
  15 minutes, and produces structured brief JSON. Scheduled Slack delivery uses
  agent-synthesized analyst-style briefs (not jq-assembled dumps). Interactive
  runs can still use the full 9-section framework. Trigger with "brief me",
  "intel brief", "osint brief", "what's going on", "latest intelligence", or
  "refresh intel".
metadata: {"nanobot":{"emoji":"🔍","requires":{"bins":["curl","jq"]}}}
---

# OSINT Intelligence Briefing

Act as a senior OSINT analyst. Query intelligence sources across three layers
(API, RSS, Twitter/X), cache results, and deliver intelligence with
topic-weighted prioritization.

## Pipeline vs presentation

- **Data pipeline (unchanged):** `brief.sh` collects API caches, RSS, and
  Twitter/X into one JSON payload. Source scripts and the intel pipeline
  (`fetch-twitter.sh`, `fetch-rss.sh`, etc.) feed that JSON.
- **Presentation (scheduled Slack):** Cron runs `deliver.sh --json <file>` to
  write raw brief JSON; the agent reads that file, synthesizes a narrative
  brief with context and links, and posts to the desk Slack channel.
- **Quick local check:** `deliver.sh --dry-run` still builds the legacy
  jq-assembled text report to stdout (no Slack) for debugging.

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
| **API** | 30+ scripts in `sources/` | API keys in `~/.wrenvps/osint/.env` |
| **RSS** | 20+ RSS feeds (SCOTUSblog, Times of Israel, CSIS, Brookings, Defense One, War on the Rocks, AJC, GPB, etc.) | `~/.wrenvps/intel/config/sources.json` |
| **Twitter/X** | 11 accounts via bird-api (Mario Nawfal, Chad Pergram, RawsAlerts, Mossad_il, Leading Report, etc.) | `~/.wrenvps/intel/config/sources.json` |

Layer orchestration:
- `brief.sh` calls `~/.wrenvps/intel/sources/fetch-all.sh` (or individual `fetch-rss.sh` / `fetch-twitter.sh`) before synthesis
- RSS cache: `~/.wrenvps/intel/cache/rss/`
- Twitter cache: `~/.wrenvps/intel/cache/twitter/`
- If bird-api is down, Twitter layer returns empty and briefing continues
- If RSS feeds fail, available feeds are used; briefing is never blocked

## Three-desk reports

Desk routing splits one mega-brief into **intel**, **investing**, and **weather** reports. Each desk has its own Slack channel, cron schedule, API allowlist, RSS/Twitter slugs, optional geo filter, and optional topic-weight key.

Merge the example into `~/.wrenvps/intel/config/topics.json`: `desks`,
`priority_topics`, `ignored_topic_phrases`, and `source_tier_classification`.
Copy from the repo:

`nanobot/skills/osint/topics.desks.example.json`

| Desk | Default role | Topic weights | Notes |
|------|----------------|---------------|--------|
| **intel** | Geopolitics, sanctions, social signals | `topic_weights`: `"priority_topics"` | Cron brief: analyst-style narrative; `--dry-run` still shows legacy ELEVATED / RSS / Twitter / Georgia subsections |
| **investing** | Markets, macro, energy, labor | `null` (no weighted ranking) | Highlight precious metals when move ≥ desk threshold (default 5%) |
| **weather** | Local hazards + models | `null` | `geo_filter` on NOAA/FIRMS/Safecast; multi-model forecasts (ECMWF / GFS / NAM) |

**API ids** in `sources.api` use underscores (`cisa_kev`, `gold_api`). Hyphenated names like `gold-api` are normalized to `gold_api` when matching scripts.

**RSS / Twitter** lists use feed slugs and handle slugs (hyphens allowed). Matching ignores hyphens/underscores and case.

**Geo filter** (weather): `states`, `counties`, `radius_miles`, and `center` `[lat,lon]`. NOAA alerts match state/county text or alert centroid within the radius. FIRMS and Safecast points are filtered by radius.

**Adding a desk:** copy a block under `desks`, set `channel`, `schedule` (for your own crons), `tz`, `sources`, `topic_weights` (string key into `topics.json` or `null`), and optional `geo_filter` / `precious_metals` / `forecast_models`.

**Commands:**

```bash
bash brief.sh --desk weather --force
bash deliver.sh --desk investing --dry-run
bash deliver.sh --desk intel --force --json /tmp/osint_brief_intel.json
```

Default if `--desk` is omitted: **`intel`** (same as pre-desk behavior when `desks` is absent: all API caches, all RSS/Twitter items).

## Topic weighting and conversational topic lists

Structured scoring still uses `~/.wrenvps/intel/config/topics.json`:

- **`priority_topics`:** keyword → weight (e.g. Iran/Israel 1.5, ICE/tariffs 1.3).
  Higher weight surfaces items earlier in ranked sections and in agent briefs.
- **`ignored_topic_phrases`:** plain-language substrings (lowercased at runtime).
  Any RSS or Twitter row whose title/headline/body contains a phrase is dropped
  after collection (before delivery). Start empty; add via conversation, e.g.
  “ignore celebrity gossip” or “suppress British royal family news.”
- **`major_event_keywords`:** items matching these can get `:rotating_light: BREAKING` urgency tags.
- **`source_tier_classification`:** **mainstream**, **alternative**, **fringe**.
  **Citizen Free Press** is treated as a preferred source: keep it under
  **alternative** (not fringe) so it ranks with elevated attention.

**Preferred topics (plain English, 2026-04-11 baseline):** Iran, Israel, ICE
Enforcement, Venezuela, Government Shutdown, Tariffs, COVID/Pandemic, Epstein
Files, DOGE Audits, Election Integrity. When the user adds interests in natural
language, map them into `priority_topics` keys and weights; do not require the
user to edit JSON by hand.

**Ignored topics:** maintain `ignored_topic_phrases` from user instructions the
same way.

## Georgia Desk

When RSS items contain Georgia-relevant content (AJC, GPB, keywords: Georgia, Atlanta, Kemp, Warnock), a **GEORGIA DESK** subsection is included in the briefing.

## Sources (API Layer)

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

### Desk-oriented additions

| # | Source | Script | Notes |
|---|--------|--------|------|
| 30 | Gold API (XAU/XAG) | `gold_api.sh` | Free JSON at `api.gold-api.com/price/{XAU,XAG}`; daily % move vs first fetch of UTC day |
| 31 | Forecast models | `forecast_models.sh` | Open-Meteo ECMWF + GFS + NAM CONUS (°F / mph); cities via `OSINT_FORECAST_CITIES_JSON` |

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
bash /path/to/skills/osint/brief.sh --desk investing --force
```

This will:
1. Check all source caches for freshness (only desks’ API scripts when `desks` is configured)
2. Fetch stale sources in parallel (15s timeout)
3. Combine cached data into a single JSON payload (desk-filtered `.sources`, RSS, Twitter)
4. Output combined intelligence data for synthesis

To refresh all caches without producing a brief:

```bash
bash /path/to/skills/osint/refresh-all.sh
```

## Automated delivery

**Production (agent-synthesized):** Cron triggers an **agent turn** (not
`shell_exec`). The agent runs `deliver.sh --desk … --force --json /tmp/…json`,
reads the JSON, writes the narrative brief, and posts to Slack.

**Legacy jq report (debug only):** `--dry-run` assembles the jq template body
and prints to stdout (no Slack, no ntfy).

**Direct post (optional):** Without `--json` or `--dry-run`, `deliver.sh` can
still post the jq-assembled body to Slack/ntfy if tokens are set (mainly for
local testing).

```bash
bash /path/to/skills/osint/deliver.sh --force
bash /path/to/skills/osint/deliver.sh --desk intel --force --json /tmp/osint_brief_intel.json
```

Supported flags:

- `--desk intel|investing|weather` selects desk config (default **`intel`**)
- `--json <filepath>` writes normalized brief JSON to a file, prints the path on
  stdout, exits (no Slack/ntfy). Use this for scheduled agent briefs.
- `--dry-run` prints the jq-assembled message without posting (mutually
  exclusive with `--json`)
- `--template intelSignal|breakingBullet` chooses briefing style (for `--dry-run` / direct post)
- `--channel-id C0AGWCQ1ZDE` overrides Slack target channel id (overrides desk `channel` when set)

Expected env vars:

- `NANOBOT_CHANNELS__SLACK__BOT_TOKEN`
- `OSINT_BRIEFING_SLACK_CHANNEL_ID` (default `C0AGWCQ1ZDE`)
- `OSINT_BRIEFING_TEMPLATE` (default `intelSignal`)
- `NTFY_URL`, `NTFY_TOPIC`, optional `NTFY_TOKEN`

## Cron setup (agent-based delivery)

Install three per-desk jobs as **`agent_turn`** payloads with `deliver=false`.
Each message instructs the agent to run `deliver.sh … --json`, read the file,
synthesize the brief, and post to the desk Slack channel.

```bash
# preview only
python /path/to/skills/osint/install_cron.py

# apply to workspace cron/jobs.json
python /path/to/skills/osint/install_cron.py --apply

# replace existing osint-* jobs after changing install script
python /path/to/skills/osint/install_cron.py --apply --replace
```

Jobs (America/New_York by default):

| Job | Default cron | Payload |
|-----|----------------|---------|
| `osint-intel` | `0 7,18 * * *` | Agent: `deliver.sh --desk intel --force --json /tmp/osint_brief_intel.json` → synthesize → `#intel-signals` |
| `osint-investing` | `0 7 * * 1-5` | Agent: `… --json /tmp/osint_brief_investing.json` → `#investing` |
| `osint-weather` | `0 6,16 * * *` | Agent: `… --json /tmp/osint_brief_weather.json` → `#weather` |

Environment overrides:

- `OSINT_BRIEFING_CRON_INTEL` (default `0 7,18 * * *`)
- `OSINT_BRIEFING_CRON_INVESTING` (default `0 7 * * 1-5`)
- `OSINT_BRIEFING_CRON_WEATHER` (default `0 6,16 * * *`)
- `NANOBOT_AGENTS__DEFAULTS__WORKSPACE` (default `~/.wrenvps/workspace`)
- `OSINT_CRON_SKILL_ROOT` — directory passed to `cd` in cron messages (default
  `/root/projects/nanobot/nanobot/skills/osint`)

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

## Source tier classification

```
Mainstream: Reuters, AP, BBC, CNN, NYT, WSJ, WaPo, Guardian, ABC, NBC, CBS, Fox News, Chad Pergram
Alternative: Substack, Rumble, BitChute, Telegram channels, Gab, Gettr, Truth Social, Mario Nawfal,
  RawsAlerts, Leading Report, Citizen Free Press (preferred; keep in alternative, not fringe)
Fringe: ZeroHedge, Infowars, NaturalNews, Gateway Pundit, Breitbart, Epoch Times, Revolver, Daily Caller
```

## Scheduled Slack brief format (agent-synthesized)

For cron-driven posts, write like an analyst morning read — not a data dump.

1. **Lead with what matters most** — priority topics first by significance.
2. **Context** — why each item matters, not only the headline.
3. **Links** — use `url` on RSS/Twitter rows, `nvd_url` on CISA KEV items,
   `series_links` on FRED, and other URLs present in the JSON for “dig deeper.”
4. **Summarize** — group related items narratively instead of listing every point.
5. **Scannable** — target under ~2 minutes’ reading time.
6. **Voice** — **Intel:** analytical/geopolitical; **Investing:** market-focused;
   **Weather:** practical and location-specific (use desk `geo_filter.cities`).

### Example: Intel desk brief

```
INTEL BRIEF | 11 Apr 2026

IRAN/ISRAEL
Ceasefire odds rising — Polymarket shows 56% chance of a new nuclear deal after the US-Iran ceasefire announcement. Netanyahu's Likud took a hit in Israeli polls, with most Israelis now opposing further escalation. Hezbollah fired a missile at Ashdod; interception debris triggered sirens in Tel Aviv. [Mario Nawfal] [Times of Israel]

US POLICY
Trump issued a statement on Tucker Carlson, Megyn Kelly, Candace Owens, and Alex Jones — no policy details yet. Congress facing pressure to reconvene. [Chad Pergram] [Citizen Free Press]

CYBER
CISA added 3 new vulnerabilities to KEV: EPMM (active exploitation), FortiClient EMS, and an unpatched client vulnerability. Patch immediately if exposed. [CISA]

Sources: 7 API | 16 RSS | 6 Twitter | 2 degraded (ACLED, GDELT)
```

### Example: Investing desk brief

```
INVESTING BRIEF | 11 Apr 2026

MARKETS
S&P 500: 6,817 (flat) | Dow: 47,917 (flat) | Nasdaq: 22,903 (flat) | VIX: 19.23
Gold: $4,771 (flat) | Silver: $76 (flat) | Crude: $95.63 | Bitcoin: $73,015

RATES
Fed Funds: 3.64% | 10Y: 4.32% | 10Y-2Y spread: +0.50bp (not inverted)
30Y Mortgage: 6.37% | 15Y Mortgage: 5.74%
Treasury Bills: 3.70% | Total US Debt: $38.9T

ECONOMIC DATA
Unemployment: 4.3% (Mar) | CPI: 330.3 (Mar) | Payroll: 158,637 (Mar)
Supply chain pressure (GSCPI): 2 data points

Sources: 7 API | 2 RSS | 0 degraded
```

### Example: Weather desk brief

```
WEATHER BRIEF | 11 Apr 2026 — Jefferson, Dahlonega, Statesboro GA

FORECAST (3-day model comparison)
Jefferson: Fri 83°F/51°F, Sat 83°F/51°F, Sun 81°F/51°F — models agree within 4°F
Dahlonega: Fri 81°F/45°F, Sat 81°F/53°F, Sun 80°F/55°F — models agree within 4°F
Statesboro: Fri 85°F/54°F, Sat 83°F/55°F, Sun 84°F/55°F — models agree within 2°F

No rain expected across all three locations through Sunday. Light winds 5-7 mph.

ALERTS
No active alerts for your area. (15 national alerts filtered out — all outside GA/surrounding states.)

Sources: 4 API | 0 degraded
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

## 9-section briefing framework (interactive / deep-dive)

When the user asks for a full analysis (not only a short Slack-style brief),
synthesize ALL available source data (API + RSS + Twitter) into this structure.

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

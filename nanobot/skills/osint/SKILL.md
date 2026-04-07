---
name: osint
description: >-
  OSINT intelligence briefing. Queries 27 open-source intelligence APIs
  (GDELT, FRED, FIRMS, EIA, BLS, CISA, markets, sanctions, conflict, weather,
  maritime, social), caches results for 15 minutes, and synthesizes a
  leverage-first 8-section briefing. Trigger with "brief me", "intel brief",
  "osint brief", "what's going on", "latest intelligence", or "refresh intel".
metadata: {"nanobot":{"emoji":"🔍","requires":{"bins":["curl","jq"]}}}
---

# OSINT Intelligence Briefing

Act as a senior OSINT analyst. Query 27 intelligence sources directly via their
public APIs, cache results, and deliver a leverage-first intelligence briefing.

## Trigger Phrases

- "brief me"
- "intel brief"
- "osint brief"
- "what's going on"
- "latest intelligence"
- "refresh intel"

## Sources (27 Total)

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

### Patents (bonus)

| 28 | USPTO Patents | `patents.sh` | Tech patents |

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

## Cache Strategy

**Rule:** No source queried more than once every 15 minutes.

- Cache dir: `{skill_dir}/cache/`
- Each source cached as `{source}.json`
- Check file mtime before fetching
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

## 8-Section Briefing Framework

When producing a brief, synthesize ALL available source data into this structure:

```
1. LEVERAGEABLE IDEAS
   3-5 specific, actionable opportunities. Each must include:
   - Thesis and instrument/sector
   - Why now (catalyst)
   - Time horizon
   - Invalidation condition
   - Confidence: High / Medium / Low

2. EXECUTIVE THESIS
   1-3 most important things happening right now. Strong view, not hedged.

3. SITUATION AWARENESS
   Top 3-5 developments. What happened, who is involved, why it matters,
   what changes.

4. PATTERN RECOGNITION
   Cross-source correlations:
   - Conflict + energy + inflation
   - Macro weakness + market stress
   - Sanctions + logistics anomalies
   - Weather + supply chain

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
```

## Output Format

- Markdown, Telegram-friendly
- No raw data dumps — synthesized judgment only
- Include relevant URLs where available
- Urgency tags: BREAKING, ELEVATED, ROUTINE
- Target ~800 words (Telegram-friendly length)
- Always state the briefing timestamp (UTC)

## Testing

1. Run individual source: `bash sources/gdelt.sh` — should return JSON
2. Check cache: `ls cache/` — files appear after fetch
3. Run full brief: `bash brief.sh` — combined intelligence output
4. Run again within 15 min — cache used, no new API calls
5. Force refresh: `bash refresh-all.sh --force`

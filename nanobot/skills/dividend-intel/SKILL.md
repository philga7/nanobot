---
name: dividend-intel
description: Dividend portfolio analysis, special dividend detection, and tax-efficient placement.
metadata: {"nanobot":{"emoji":"💰","requires":{"bins":["curl","python3"]},"install":["pip install yfinance"]}}
---

# dividend-intel

Tools for dividend portfolio analysis, special dividend detection, and tax-efficient account placement. All commands use `curl` and `python3` with `yfinance` — no API keys required.

## Portfolio data (JSON)

All holdings, strategy rules, and market state live in a **single JSON file**.

- **Default path:** `~/.wrenvps/dividend-intel/portfolio.json`
- **Override:** set env `DIVIDEND_INTEL_PORTFOLIO` to an absolute path.
- **Template:** copy [portfolio.example.json](portfolio.example.json) from this skill directory and edit in place.

**Schema:**

| Field | Required | Description |
|---|---|---|
| `holdings` | **yes*** | Object keyed by ticker → `{shares, name, div_type?, state?}` |
| `portfolio` | *fallback* | Flat array of ticker strings — used if `holdings` is absent |
| `strategy` | no | `{buyCondition, sellCondition, buyDay, notes}` — surfaced in digests |
| `screener_universe` | no | Extra tickers for `yield_screener`; defaults to `holdings` keys if absent |
| `exclude_from_screener` | no | Tickers to skip in screener |
| `version` / `owner` / `lastUpdated` | no | Metadata — preserved, ignored by scripts |

**`holdings[ticker]` sub-fields:**

| Field | Required | Description |
|---|---|---|
| `shares` | yes | Number of shares held — shown in sweep output |
| `name` | no | Human-readable company name |
| `div_type` | no | `"qualified"`, `"non-qualified"`, `"reit"`, `"bdc"`, `"mlp"` — used by `account_optimizer` |
| `state` | no | Derived/ephemeral SMA data: `{price, sma200, above, pct_diff}`. Refreshed by a separate agent cron — never hand-edit. |

*If both `holdings` and `portfolio` are absent, every tool exits with a clear error.

**Ticker resolution order (all tools):**
1. `holdings` keys (preferred — includes shares, div_type, state)
2. `portfolio` array (legacy fallback)
3. Error if neither exists

## Tools

| Tool | Purpose |
|---|---|
| portfolio_sweep | Sweep holdings for upcoming ex-div dates, yield, payout ratio |
| special_dividend_scanner | Scan SEC 8-Ks for special/extra dividend announcements |
| dividend_calendar | Sorted upcoming ex-div / pay date calendar |
| yield_screener | Find new positions matching yield/growth/safety criteria |
| account_optimizer | Recommend tax-efficient account placement |

---

## 1. portfolio_sweep / dividend_calendar

Fetch upcoming ex-dividend dates, yield, payout ratio, and share count for all holdings within a day window. Includes SMA200 regime and buy-signal flag from `state` when available.

```bash
python3 -c "
import os, yfinance as yf, json, sys
from datetime import datetime, timezone

OPTION_INCOME_ETFS = {
    'XDTE','QDTE','YMAX','ULTY','JEPI','JEPQ','DIVO',
    'XYLD','QYLD','RYLD','SDIV','TSLY','NVDY','AMZY',
}

path = os.environ.get('DIVIDEND_INTEL_PORTFOLIO', os.path.expanduser('~/.wrenvps/dividend-intel/portfolio.json'))
with open(path, encoding='utf-8') as f:
    data = json.load(f)
if 'holdings' in data:
    holdings = data['holdings']
    tickers = list(holdings.keys())
elif 'portfolio' in data:
    holdings = {}
    tickers = [str(t).upper().strip() for t in data['portfolio']]
else:
    raise SystemExit('dividend-intel: portfolio.json missing required key. Expected holdings object or portfolio array. See portfolio.example.json.')
strategy = data.get('strategy', {})
buy_day = strategy.get('buyDay', '')
window = int(sys.argv[1])
results = []
for t in tickers:
    meta = holdings.get(t, {})
    state = meta.get('state', {})
    is_option_etf = t in OPTION_INCOME_ETFS
    try:
        tk = yf.Ticker(t)
        info = tk.info
        ex_raw = info.get('exDividendDate')
        if ex_raw:
            ex_dt = datetime.fromtimestamp(ex_raw, tz=timezone.utc)
            days_out = (ex_dt - datetime.now(tz=timezone.utc)).days
        else:
            ex_dt = None
            days_out = None
        if days_out is not None and days_out < 0:
            ex_date_str = 'upcoming TBD'
            days_out = None
        else:
            ex_date_str = ex_dt.strftime('%Y-%m-%d') if ex_dt else 'unknown'
        rate = info.get('dividendRate') or 0
        price = info.get('currentPrice') or info.get('regularMarketPrice') or 0
        raw_yld = info.get('dividendYield') or 0
        if rate > 0 and price > 0:
            yield_pct = round(rate / price * 100, 2)
        else:
            yield_pct = round(raw_yld, 2)
        payout_pct = round((info.get('payoutRatio') or 0) * 100, 1)
        div_type = meta.get('div_type', '')
        payout_note = ''
        if payout_pct > 100 and div_type in ('reit', 'bdc'):
            payout_note = 'use FFO/NII, not EPS'
        elif payout_pct > 100:
            payout_note = 'check FCF payout — may be GAAP distortion'
        row = {
            'ticker': t,
            'name': meta.get('name') or info.get('shortName', ''),
            'shares': meta.get('shares'),
            'yield_pct': yield_pct,
            'forward_annual': rate if rate else None,
            'ex_date': ex_date_str,
            'days_until_ex': days_out,
            'payout_ratio': payout_pct,
            'in_window': days_out is not None and 0 <= days_out <= window,
        }
        if is_option_etf:
            row['yield_type'] = 'option-premium'
            row['yield_note'] = 'yield from option premium decay — not a traditional dividend; distributions erode NAV'
        if payout_note:
            row['payout_note'] = payout_note
        if state:
            row['price'] = state.get('price')
            row['sma200'] = state.get('sma200')
            row['above_sma200'] = state.get('above')
            row['buy_candidate'] = (not state.get('above', True))
        results.append(row)
    except Exception as e:
        results.append({'ticker': t, 'error': str(e)})
standard = [r for r in results if r.get('in_window', False) and not r.get('yield_type')]
option_etfs = [r for r in results if r.get('in_window', False) and r.get('yield_type') == 'option-premium']
standard.sort(key=lambda r: r.get('days_until_ex') or 9999)
option_etfs.sort(key=lambda r: r.get('days_until_ex') or 9999)
if buy_day:
    for r in standard:
        if r.get('buy_candidate'):
            r['note'] = f'Buy candidate per strategy — check if today is {buy_day}'
print(json.dumps({'ex_div_calendar': standard, 'option_income_etfs': option_etfs}, indent=2))
" "60"
```

Arg: `window_days`. Reads `holdings` first, falls back to `portfolio` array. Output has two sections:
- `ex_div_calendar` — standard dividend holdings with upcoming ex-dates
- `option_income_etfs` — XDTE/QDTE/YMAX/ULTY etc. flagged separately with `yield_note`

Stale past ex-dates (`days_until_ex < 0`) are silently replaced with `"upcoming TBD"` and excluded from both sections.

---

## 2. special_dividend_scanner

Scan SEC EDGAR 8-K filings for special/extra dividend announcements in the last N days.

### Reactive layer — announced specials

```bash
SINCE=$(python3 -c "from datetime import datetime,timedelta; print((datetime.now()-timedelta(days=14)).strftime('%Y-%m-%d'))")
curl -s -H "User-Agent: dividend-intel/1.0 (nanobot@local)" \
  "https://efts.sec.gov/LATEST/search-index?q=%22special+dividend%22+%22per+share%22&dateRange=custom&startdt=${SINCE}&forms=8-K"
```

Parse the JSON response: `hits.hits[]._source` contains `entity_name`, `file_date`, `accession_no`, `entity_id`.

### Proactive layer — asset sale completions (Item 2.01)

Companies completing major asset dispositions often follow with special dividends.

```bash
SINCE=$(python3 -c "from datetime import datetime,timedelta; print((datetime.now()-timedelta(days=14)).strftime('%Y-%m-%d'))")
curl -s -H "User-Agent: dividend-intel/1.0 (nanobot@local)" \
  "https://efts.sec.gov/LATEST/search-index?q=%22Item+2.01%22+%22disposition%22&dateRange=custom&startdt=${SINCE}&forms=8-K"
```

Flag these as `signal: asset-sale-completed — monitor for special dividend`.

---

## 3. yield_screener

Screen for dividend positions meeting custom criteria. Tickers come from `screener_universe` if present, otherwise `holdings` keys, otherwise `portfolio` array. Skips `exclude_from_screener`.

```bash
python3 -c "
import os, yfinance as yf, json, sys

path = os.environ.get('DIVIDEND_INTEL_PORTFOLIO', os.path.expanduser('~/.wrenvps/dividend-intel/portfolio.json'))
with open(path, encoding='utf-8') as f:
    data = json.load(f)
if 'screener_universe' in data:
    universe = [str(t).upper().strip() for t in data['screener_universe']]
elif 'holdings' in data:
    universe = list(data['holdings'].keys())
elif 'portfolio' in data:
    universe = [str(t).upper().strip() for t in data['portfolio']]
else:
    raise SystemExit('dividend-intel: portfolio.json missing required key. Expected holdings object or portfolio array. See portfolio.example.json.')
exclude = set(str(x).upper().strip() for x in data.get('exclude_from_screener', []))
min_yield = float(sys.argv[1])
max_payout = float(sys.argv[2])
results = []
for t in universe:
    if t in exclude:
        continue
    try:
        info = yf.Ticker(t).info
        rate = info.get('dividendRate') or 0
        price = info.get('currentPrice') or info.get('regularMarketPrice') or 0
        raw_yld = info.get('dividendYield') or 0
        yld = round(rate / price * 100, 2) if rate > 0 and price > 0 else round(raw_yld, 2)
        payout = (info.get('payoutRatio') or 0) * 100
        if yld >= min_yield and 0 < payout <= max_payout:
            results.append({
                'ticker': t,
                'name': info.get('shortName', ''),
                'sector': info.get('sector', ''),
                'yield_pct': round(yld, 2),
                'payout_ratio': round(payout, 1),
                'price': info.get('currentPrice'),
            })
    except Exception:
        pass
results.sort(key=lambda r: r['yield_pct'], reverse=True)
print(json.dumps(results[:25], indent=2))
" "3.0" "80"
```

Args: `min_yield max_payout`. Add tickers to `screener_universe` in the JSON file to widen the scan beyond current holdings.

---

## 4. account_optimizer

Recommend optimal account placement for holdings. Uses `div_type` from `holdings[ticker]` when set; otherwise infers from sector/name or asks the user. Ranks by estimated annual tax savings.

### Decision rules

| `div_type` | Recommended account | Why |
|---|---|---|
| `reit` | Tax-advantaged | Ordinary income distributions (up to 37%) |
| `bdc` | Tax-advantaged | Non-qualified, ordinary income rates |
| `mlp` | Tax-advantaged | Ordinary income in taxable |
| `non-qualified` | Tax-advantaged | Taxed at marginal rate, not preferential rate |
| `qualified` | Taxable | 0/15/20% LTCG rates; step-up in basis at death |

### Tax drag formula

```
annual_tax_savings_per_dollar = (marginal_rate - 0.15) * dividend_yield
```

Example: a 5% yielding REIT at 24% marginal rate in the wrong account wastes `(0.24 - 0.15) × 0.05 = $4.50/year per $1,000 invested`.

When running account_optimizer, load `holdings` from `portfolio.json`, use each entry's `div_type` field, apply the rules above, and rank by potential savings highest first. Holdings without `div_type` should be flagged for classification.

---

## 5. Morning digest cron

Set up a daily 7 AM cron job that sweeps holdings, scans for special dividends, screens for new picks, and delivers a Telegram digest.

```
Schedule: 0 7 * * * (tz: America/New_York or user's local)

Task:
1. Load portfolio.json — read strategy.buyDay and strategy.buyCondition
2. Run portfolio_sweep for next 45 days (reads holdings from portfolio.json)
3. Check today's day of week against strategy.buyDay
4. Run special_dividend_scanner for last 7 days
5. Run yield_screener with min_yield=3.5, max_payout=75
6. Compose Telegram digest:

   EX-DIV THIS WEEK
   [ticker] ([shares] shares) — ex [date], yield [X]%, pays $[forward_annual/4]
   [if buy_candidate and today=buyDay: "★ BUY CANDIDATE — below SMA200"]

   SPECIAL DIVIDENDS DETECTED
   [company] — filed [date] ([link])
   (or: None detected this week)

   SCREENER TOP PICKS
   1. [ticker] — [yield]% yield, [payout]% payout, [sector]
   2. ...
   3. ...

   STRATEGY NOTE
   Buy condition: [strategy.buyCondition] | Buy day: [strategy.buyDay]
   [X] holdings currently below SMA200 — [list tickers]

7. Send digest to Telegram
```

Use the nanobot cron system (`kind: "cron"`, `expr: "0 7 * * *"`, `tz: "America/New_York"`).

**`portfolio_state` is derived data.** The `state` object inside each `holdings` entry (`price`, `sma200`, `above`, `pct_diff`) is refreshed by a separate agent cron that calls yfinance and writes back to `portfolio.json`. It is never hand-edited. If `state` is absent for a ticker, the sweep omits SMA fields gracefully.

---

## Dual-Account Framework

Asset location optimization — place assets where their tax drag is minimized.

| Account Type | What Goes In | Why |
|---|---|---|
| Tax-Advantaged (401k/Roth) | REITs, BDCs, MLPs, non-qualified dividends, high-yield bonds | Ordinary income dividends taxed up to 37% in taxable — sheltering is highest value |
| Taxable Brokerage | Dividend Aristocrats, qualified dividend growers, international dividend ETFs | Qualified dividends taxed at 0/15/20% LTCG rates — tax-efficient in taxable |

Non-qualified dividend payers belong in tax-advantaged accounts. Qualified dividend growers belong in taxable.

---

## Special Dividend Alpha Taxonomy

Special dividends are irregular, underfollowed by retail investors, and represent genuine alpha opportunities.

### Previously Identified (Well-Known)

- **Energy producers post-commodity windfall** — CVX, XOM, DVN and peers after oil/gas price cycles. Fortress balance sheets and no capex needs route cash to specials.
- **REITs selling major assets** — required by IRS to distribute net gains from asset sales as special dividends. Watch for 8-K Item 2.01 (asset sale completion) filings.
- **BDCs with over-earned NII** — Business Development Companies earning above stated distribution must pay spillover income. Watch quarterly earnings vs. stated distribution.
- **Small/mid-cap industrials with fortress balance sheets + activist pressure** — 13D/13G activist filings on net-cash-heavy companies are a leading indicator.
- **Post-spinoff parent companies** — distributing accumulated excess cash to clean balance sheets after spinning off a division.

### Corporate Event-Driven

- **Post-major asset sale (any sector)** — utilities, food conglomerates, industrials selling divisions. Any company closing a significant asset sale (8-K Item 2.01) may distribute proceeds.
- **Pre-going-private / LBO targets** — distributing cash before a buyout closes. Watch merger agreement filings for dividend provisions.
- **Post-merger excess cash** — acquirer has leftover deal financing and returns it to shareholders.
- **Litigation settlement windfalls** — patent wins, antitrust settlements, large insurance payouts create one-time cash positions.
- **Capex cycle completion** — companies that held cash reserves for a major project (pipeline, plant, data center) that just finished and no longer need the reserve.

### Sector-Specific Patterns

- **Biotech/pharma with failed or completed M&A** — excess escrow cash or milestone payments from terminated or completed acquisitions.
- **Commodity royalty trusts** during high price environments — oil, gas, coal trusts have mandatory distribution rules tied to commodity prices.
- **Shipping companies (dry bulk, tankers)** — cyclical cash machines. Companies like Star Bulk routinely pay large specials at cycle peaks.
- **Timber REITs** after major land parcel sales.
- **CLOs and Closed-End Funds (CEFs)** with over-earned income exceeding required distributions.
- **Financial holding companies** returning excess regulatory capital (banks post-stress-test capital return approval from the Fed).
- **Insurance companies** after demutualization events or reserve releases.

### Structural / Policy-Driven

- **Tax law changes** — the 2017 TCJA triggered a wave of repatriation specials from cash-rich tech. Any future tax reform creates the same window. Monitor congressional activity.
- **Foreign private issuers with variable payout policies** — European (Hermes, Airbus), Australian, and UK companies routinely pay variable/special dividends as standard policy. Underfollowed by US retail investors.
- **S-Corp and pass-through entities converting to C-Corp** — clearing out retained earnings at conversion.
- **Companies completing share buyback authorizations** that pivot to one-time dividends instead.

### Quantitative Triggers (Pre-Announcement Alpha)

- **Net cash > market cap situations** — deeply undervalued companies where activist pressure eventually forces a special. Screen for EV < 0.
- **Dividend recaps from private equity exits** — PE-backed companies paying down debt post-IPO, then distributing remaining cash.
- **MLPs after dropdown transactions** completing asset transfers to their GP.

### Two-Layer Scan Strategy

1. **Reactive layer** — SEC EDGAR 8-K scanner catches formal announcements (ex-date, amount). This is `special_dividend_scanner` above.
2. **Proactive layer** — Thematic screener watches for pre-announcement conditions: net-cash-to-market-cap ratios, 8-K Item 2.01 (asset sale completed), capex project completions, and incoming activist 13D/13G filings. This is where real alpha lives — catching the setup before the announcement.

---

## SMA200 State Refresh Cron

Run weekly to keep `holdings[ticker].state` current. Required for accurate buy signals.

- **Schedule:** Monday 3:00 AM ET (`0 3 * * 1`, `America/New_York`)
- **Script:** `scripts/dividend-state-refresh.sh` (install to `~/.wrenvps/scripts/`)
- **What it does:** Fetches 200-day SMA, current price, above/below status for all holdings
- **Output:** Silent on success, logs errors to stderr on failure
- **Why it matters:** `portfolio_sweep` buy signals depend on current SMA200 state

### Setup

1. Copy and install the script:

```bash
mkdir -p ~/.wrenvps/scripts
cp /path/to/skill/scripts/dividend-state-refresh.sh ~/.wrenvps/scripts/
chmod +x ~/.wrenvps/scripts/dividend-state-refresh.sh
```

2. Register the cron job via the nanobot cron tool:

```
Name: dividend_state_refresh
cron_expr: 0 3 * * 1
tz: America/New_York
message: bash ~/.wrenvps/scripts/dividend-state-refresh.sh
deliver: false
shell_exec: true
```

Or via the agent (tell the agent):

> "Add a cron job named dividend_state_refresh to run `bash ~/.wrenvps/scripts/dividend-state-refresh.sh` on schedule `0 3 * * 1` in timezone `America/New_York`, silent, no delivery."

---

## Notes

- SEC EDGAR requests require a `User-Agent` header with contact info. The commands above use `dividend-intel/1.0 (nanobot@local)`.
- `yfinance` is the underlying data provider. No API key required. Install with `pip install yfinance`.
- All tools work with any model that supports shell execution.

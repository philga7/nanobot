#!/bin/bash
# Refreshes SMA200 state for all holdings in portfolio.json
# Called by cron — silent on success, logs on failure
#
# Install:
#   cp /path/to/skill/scripts/dividend-state-refresh.sh ~/.wrenvps/scripts/
#   chmod +x ~/.wrenvps/scripts/dividend-state-refresh.sh
#
# Cron: 0 3 * * 1 (America/New_York) — Monday 3:00 AM ET

python3 << 'EOF'
import os, yfinance as yf, json
from datetime import datetime, timezone

path = os.environ.get('DIVIDEND_INTEL_PORTFOLIO', os.path.expanduser('~/.wrenvps/dividend-intel/portfolio.json'))
with open(path, encoding='utf-8') as f:
    data = json.load(f)

holdings = data.get('holdings', {})
updated = 0
errors = []

for ticker in holdings:
    try:
        tk = yf.Ticker(ticker)
        info = tk.info
        price = info.get('currentPrice') or info.get('regularMarketPrice') or 0
        if not price:
            errors.append(f"{ticker}: no price")
            continue

        hist = tk.history(period="200d")
        if len(hist) < 50:
            errors.append(f"{ticker}: insufficient history ({len(hist)} days)")
            continue

        sma200 = round(float(hist['Close'].iloc[-200:].mean()), 2) if len(hist) >= 200 else round(float(hist['Close'].mean()), 2)
        above = bool(price > sma200)
        pct_diff = round((price - sma200) / sma200 * 100, 2)

        holdings[ticker]['state'] = {
            'price': price,
            'sma200': sma200,
            'above': above,
            'pct_diff': pct_diff,
            'sma200_source': 'yfinance_200d',
            'refreshed': datetime.now(tz=timezone.utc).isoformat()
        }
        updated += 1
    except Exception as e:
        errors.append(f"{ticker}: {str(e)}")

data['lastUpdated'] = datetime.now(tz=timezone.utc).isoformat()
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)

print(f"Updated: {updated} | Errors: {len(errors)}")
for e in errors:
    print(f"  {e}", flush=True)
EOF

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="yfinance"
CACHE_FILE="${CACHE_DIR}/${SOURCE}.json"
CACHE_MAX_AGE=900

force=false
[[ "${1:-}" == "--force" ]] && force=true

if [[ "$force" == "false" && -f "$CACHE_FILE" ]]; then
  file_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
  if (( file_age < CACHE_MAX_AGE )); then
    cat "$CACHE_FILE"
    exit 0
  fi
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

symbols=("^GSPC" "^DJI" "^IXIC" "^VIX" "GC=F" "CL=F" "BTC-USD" "^TNX")
names=("SP500" "DowJones" "Nasdaq" "VIX" "Gold" "CrudeOil" "Bitcoin" "10YTreasury")
markets="{"

for i in "${!symbols[@]}"; do
  sym="${symbols[$i]}"
  name="${names[$i]}"
  encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${sym}'))" 2>/dev/null || echo "$sym")

  data=$(curl -sf --max-time 8 \
    -H "User-Agent: Mozilla/5.0" \
    "https://query1.finance.yahoo.com/v8/finance/chart/${encoded}?range=5d&interval=1d" 2>/dev/null) || data="{}"

  price=$(echo "$data" | jq -r '.chart.result[0].meta.regularMarketPrice // empty' 2>/dev/null) || price=""
  prev=$(echo "$data" | jq -r '.chart.result[0].meta.previousClose // empty' 2>/dev/null) || prev=""
  currency=$(echo "$data" | jq -r '.chart.result[0].meta.currency // "USD"' 2>/dev/null) || currency="USD"

  if [[ -n "$price" && -n "$prev" && "$prev" != "0" ]]; then
    change=$(python3 -c "p=${price};c=${prev};print(round(((p-c)/c)*100,2))" 2>/dev/null) || change="0"
  else
    change="0"
  fi

  [[ $i -gt 0 ]] && markets+=","
  markets+="\"${name}\":{\"price\":${price:-0},\"prev_close\":${prev:-0},\"change_pct\":${change},\"currency\":\"${currency}\"}"
done

markets+="}"

result=$(jq -nc --arg ts "$ts" --argjson markets "$markets" '{
  source: "yfinance",
  fetched_at: $ts,
  markets: $markets
}')

echo "$result" | tee "$CACHE_FILE"

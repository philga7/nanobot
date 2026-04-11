#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="fred"
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
KEY="${OSINT_FRED_API_KEY:-}"

if [[ -z "$KEY" ]]; then
  result="{\"source\":\"${SOURCE}\",\"error\":\"OSINT_FRED_API_KEY not set\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
fi

BASE="https://api.stlouisfed.org/fred/series/observations"
series_ids=("DFF" "CPIAUCSL" "UNRATE" "T10Y2Y" "VIXCLS" "MORTGAGE30US" "MORTGAGE15US")
series_json="{"

for i in "${!series_ids[@]}"; do
  sid="${series_ids[$i]}"
  data=$(curl -sf --max-time 10 \
    "${BASE}?series_id=${sid}&api_key=${KEY}&file_type=json&sort_order=desc&limit=5" 2>/dev/null) || data="{}"
  obs=$(echo "$data" | jq -c '[(.observations // [])[:5][] | {date, value}]' 2>/dev/null) || obs="[]"
  [[ $i -gt 0 ]] && series_json+=","
  series_json+="\"${sid}\":${obs}"
done

series_json+="}"

result=$(jq -nc --arg ts "$ts" --argjson series "$series_json" '{
  source: "fred",
  fetched_at: $ts,
  series: $series
}')

echo "$result" | tee "$CACHE_FILE"

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="eia"
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
KEY="${OSINT_EIA_API_KEY:-}"

if [[ -z "$KEY" ]]; then
  result="{\"source\":\"${SOURCE}\",\"error\":\"OSINT_EIA_API_KEY not set\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
fi

raw=$(curl -sf --max-time 10 \
  "https://api.eia.gov/v2/petroleum/pri/spt/data/?api_key=${KEY}&frequency=daily&data[0]=value&sort[0][column]=period&sort[0][direction]=desc&length=10" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "eia",
  fetched_at: $ts,
  count: (.response.data // [] | length),
  data: [(.response.data // [])[:10][] | {period, product, area, value, units: "$/barrel"}]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

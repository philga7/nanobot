#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="acled"
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
EMAIL="${OSINT_ACLED_EMAIL:-}"
PASSWORD="${OSINT_ACLED_PASSWORD:-}"

if [[ -z "$EMAIL" || -z "$PASSWORD" ]]; then
  result="{\"source\":\"${SOURCE}\",\"status\":\"degraded\",\"degraded\":true,\"reason\":\"OSINT_ACLED_EMAIL or OSINT_ACLED_PASSWORD not set\",\"count\":0,\"events\":[],\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
fi

# Dynamic date filter: events from the last 7 days
event_date=$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d 2>/dev/null || echo "")

ACLED_URL="https://api.acleddata.com/acled/read?key=${PASSWORD}&email=${EMAIL}&limit=20"
if [[ -n "$event_date" ]]; then
  ACLED_URL="${ACLED_URL}&event_date=${event_date}&event_date_where=%3E%3D"
fi

# Try primary endpoint; fall back with DNS pinning if resolution fails
http_code=$(curl -s -o /tmp/acled_raw.json -w "%{http_code}" --max-time 15 "$ACLED_URL" 2>/dev/null) || http_code="000"

if [[ "$http_code" == "000" ]]; then
  # DNS or network failure — retry with Cloudflare IP pinning
  http_code=$(curl -s -o /tmp/acled_raw.json -w "%{http_code}" --max-time 15 \
    --resolve "api.acleddata.com:443:172.66.175.97" "$ACLED_URL" 2>/dev/null) || http_code="000"
fi

if [[ "$http_code" != "200" ]]; then
  body=$(head -c 200 /tmp/acled_raw.json 2>/dev/null | tr '"' "'" || echo "")
  result=$(jq -nc \
    --arg ts "$ts" \
    --arg code "$http_code" \
    --arg detail "$body" \
    '{
      source: "acled",
      status: "degraded",
      degraded: true,
      reason: ("ACLED endpoint unavailable (HTTP " + $code + ")"),
      detail: $detail,
      count: 0,
      events: [],
      fetched_at: $ts
    }')
  echo "$result" | tee "$CACHE_FILE"
  rm -f /tmp/acled_raw.json
  exit 0
fi

raw=$(cat /tmp/acled_raw.json)
rm -f /tmp/acled_raw.json

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "acled",
  fetched_at: $ts,
  count: (.data // [] | length),
  events: [(.data // [])[:20][] | {
    event_date, event_type, sub_event_type, actor1, country, location, fatalities, notes
  }]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

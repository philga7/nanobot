#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="gdelt"
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

GDELT_URL="https://api.gdeltproject.org/api/v2/doc/doc?query=conflict%20OR%20crisis%20OR%20military&mode=ArtList&maxrecords=15&format=json&sort=DateDesc"

# GDELT rate-limits to 1 request per 5 seconds per IP
http_code=$(curl -s -o /tmp/gdelt_raw.json -w "%{http_code}" --max-time 20 "$GDELT_URL" 2>/dev/null) || http_code="000"

if [[ "$http_code" == "429" || "$http_code" == "000" ]]; then
  # Rate limited or timeout — retry after backoff
  sleep 6
  http_code=$(curl -s -o /tmp/gdelt_raw.json -w "%{http_code}" --max-time 20 "$GDELT_URL" 2>/dev/null) || http_code="000"
fi

if [[ "$http_code" != "200" ]]; then
  body=$(head -c 200 /tmp/gdelt_raw.json 2>/dev/null | tr '"' "'" || echo "")
  result="{\"source\":\"${SOURCE}\",\"error\":\"HTTP ${http_code}\",\"detail\":\"${body}\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  rm -f /tmp/gdelt_raw.json
  exit 0
fi

raw=$(cat /tmp/gdelt_raw.json)
rm -f /tmp/gdelt_raw.json

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "gdelt",
  fetched_at: $ts,
  count: (.articles // [] | length),
  articles: [(.articles // [])[:15][] | {title, url, seendate, domain, language}]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

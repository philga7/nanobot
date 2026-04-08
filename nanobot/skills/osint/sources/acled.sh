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
  result="{\"source\":\"${SOURCE}\",\"error\":\"OSINT_ACLED_EMAIL or OSINT_ACLED_PASSWORD not set\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
fi

# Warn if key looks too short (ACLED keys are typically 32+ chars)
if (( ${#PASSWORD} < 20 )); then
  echo "WARNING: OSINT_ACLED_PASSWORD is only ${#PASSWORD} chars (expected 32+). May be invalid/expired." >&2
fi

# Test DNS resolution before the API call to give a clearer error
if ! host api.acleddata.com > /dev/null 2>&1 && ! nslookup api.acleddata.com > /dev/null 2>&1; then
  result="{\"source\":\"${SOURCE}\",\"error\":\"DNS resolution failed for api.acleddata.com — check network/DNS config\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
fi

raw=$(curl -sf --max-time 15 \
  "https://api.acleddata.com/acled/read?key=${PASSWORD}&email=${EMAIL}&limit=20&page=1" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed (check credentials and network)\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

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

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="noaa"
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

raw=$(curl -sf --max-time 10 \
  -H "User-Agent: nanobot-osint/1.0 (contact@nanobot.local)" \
  "https://api.weather.gov/alerts/active?severity=Extreme,Severe&limit=15" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "noaa",
  fetched_at: $ts,
  count: (.features // [] | length),
  alerts: [(.features // [])[:15][] | {
    headline: .properties.headline,
    severity: .properties.severity,
    event: .properties.event,
    area: .properties.areaDesc,
    onset: .properties.onset,
    expires: .properties.expires,
    status: .properties.status
  }]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

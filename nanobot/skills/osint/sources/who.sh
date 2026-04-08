#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="who"
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

# WHO Disease Outbreak News — JSON API (RSS feed is defunct)
raw=$(curl -sf --max-time 10 \
  'https://www.who.int/api/hubs/diseaseoutbreaknews?$top=10&$orderby=PublicationDate%20desc' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "who",
  fetched_at: $ts,
  count: (.value // [] | length),
  outbreaks: [(.value // [])[:10][] | {
    title: .Title,
    date: .PublicationDate,
    id: .Id,
    url: ("https://www.who.int/emergencies/disease-outbreak-news/" + (.UrlName // ""))
  }]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="reliefweb"
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

raw=$(curl -sf -g --max-time 10 \
  "https://api.reliefweb.int/v2/reports?appname=nanobot-osint&limit=15&preset=latest&fields%5Binclude%5D%5B%5D=title&fields%5Binclude%5D%5B%5D=url&fields%5Binclude%5D%5B%5D=date.created&fields%5Binclude%5D%5B%5D=source.name&fields%5Binclude%5D%5B%5D=country.name" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "reliefweb",
  fetched_at: $ts,
  count: (.count // 0),
  reports: [(.data // [])[:15][] | {
    title: .fields.title,
    url: .fields.url,
    date: .fields.date.created,
    source: [(.fields.source // [])[] | .name],
    country: [(.fields.country // [])[] | .name]
  }]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

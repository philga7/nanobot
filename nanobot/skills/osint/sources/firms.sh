#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="firms"
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
KEY="${OSINT_FIRMS_MAP_KEY:-}"

if [[ -z "$KEY" ]]; then
  result="{\"source\":\"${SOURCE}\",\"error\":\"OSINT_FIRMS_MAP_KEY not set\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
fi

raw=$(curl -sf --max-time 15 \
  "https://firms.modaps.eosdis.nasa.gov/api/area/csv/${KEY}/VIIRS_SNPP_NRT/world/1" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

hotspots=$(echo "$raw" | awk -F',' 'NR>1 && NR<=21 {
  gsub(/"/, "", $0)
  printf "{\"latitude\":\"%s\",\"longitude\":\"%s\",\"brightness\":\"%s\",\"confidence\":\"%s\",\"acq_date\":\"%s\",\"acq_time\":\"%s\"},", $1, $2, $3, $10, $6, $7
}' | sed 's/,$//')

count=$(echo "$raw" | tail -n +2 | head -20 | wc -l | tr -d ' ')

result="{\"source\":\"${SOURCE}\",\"fetched_at\":\"${ts}\",\"count\":${count},\"hotspots\":[${hotspots}]}"
echo "$result" | tee "$CACHE_FILE"

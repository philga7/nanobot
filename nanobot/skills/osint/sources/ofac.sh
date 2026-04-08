#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="ofac"
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

headers=$(curl -sI --max-time 10 \
  "https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/CONSOLIDATED.XML" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

last_modified=$(echo "$headers" | grep -i "last-modified" | sed 's/[Ll]ast-[Mm]odified: *//;s/\r//' | head -1 || true)
content_length=$(echo "$headers" | grep -i "content-length" | sed 's/[Cc]ontent-[Ll]ength: *//;s/\r//' | head -1 || true)

result=$(jq -nc --arg ts "$ts" --arg lm "${last_modified:-unknown}" --arg cl "${content_length:-unknown}" '{
  source: "ofac",
  fetched_at: $ts,
  last_updated: $lm,
  file_size_bytes: $cl,
  status: "checked"
}')

echo "$result" | tee "$CACHE_FILE"

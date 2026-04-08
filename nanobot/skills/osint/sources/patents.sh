#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="patents"
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

# Google Patents public search (USPTO IBD API is decomissioned)
PATENTS_URL="https://patents.google.com/xhr/query?url=q%3Dartificial+intelligence&num=10&type=patent&sort=new"

http_code=$(curl -s -o /tmp/patents_raw.json -w "%{http_code}" --max-time 15 "$PATENTS_URL" 2>/dev/null) || http_code="000"

if [[ "$http_code" != "200" ]]; then
  body=$(head -c 200 /tmp/patents_raw.json 2>/dev/null | tr '"' "'" || echo "")
  result="{\"source\":\"${SOURCE}\",\"error\":\"HTTP ${http_code}\",\"detail\":\"${body}\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  rm -f /tmp/patents_raw.json
  exit 0
fi

raw=$(cat /tmp/patents_raw.json)
rm -f /tmp/patents_raw.json

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "patents",
  fetched_at: $ts,
  total: .results.total_num_results,
  count: ([.results.cluster[0].result // [] | .[:10][]] | length),
  patents: [.results.cluster[0].result // [] | .[:10][] | {
    title: (.patent.title | gsub("<[^>]*>"; "")),
    id: .patent.publication_number,
    priority_date: .patent.priority_date,
    filing_date: .patent.filing_date,
    inventor: .patent.inventor,
    assignee: .patent.assignee
  }]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

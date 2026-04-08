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

USPTO_URL="https://developer.uspto.gov/ibd-api/v1/application/publications?searchText=artificial+intelligence&start=0&rows=10"

raw=$(curl -sf --max-time 10 "$USPTO_URL" 2>/dev/null) || {
  # Single retry — USPTO often returns 503 intermittently
  sleep 3
  raw=$(curl -sf --max-time 10 "$USPTO_URL" 2>/dev/null) || {
    result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed (after retry)\",\"fetched_at\":\"${ts}\"}"
    echo "$result" | tee "$CACHE_FILE"
    exit 0
  }
}

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "patents",
  fetched_at: $ts,
  count: (.results // [] | length),
  patents: [(.results // [])[:10][] | {
    title: .inventionTitle,
    patent_number: .patentNumber,
    filing_date: .filingDate,
    applicant: .applicantName,
    abstract: (.abstractText // "" | .[:200])
  }]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

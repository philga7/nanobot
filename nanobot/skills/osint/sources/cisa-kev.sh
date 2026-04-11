#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="cisa_kev"
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
  "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "cisa_kev",
  fetched_at: $ts,
  catalog_version: .catalogVersion,
  total_count: (.vulnerabilities | length),
  count: 10,
  vulnerabilities: [(.vulnerabilities | sort_by(.dateAdded) | reverse)[:10][] | {
    cveID, vendorProject, product, vulnerabilityName, dateAdded, dueDate, knownRansomwareCampaignUse,
    nvd_url: ("https://nvd.nist.gov/vuln/detail/" + .cveID)
  }]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

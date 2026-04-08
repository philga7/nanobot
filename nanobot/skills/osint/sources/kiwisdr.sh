#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="kiwisdr"
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

# KiwiSDR receiver list
raw=$(curl -sf --max-time 10 \
  "http://rx.linkfanel.net/kiwisdr_com.js" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

result=$(python3 -c "
import json, sys, re

data = sys.stdin.read()
# The JS file contains a variable assignment with a JSON array
match = re.search(r'\[.*\]', data, re.DOTALL)
if not match:
    print(json.dumps({'source': 'kiwisdr', 'error': 'parse failed', 'fetched_at': '$ts'}))
    sys.exit(0)

try:
    # KiwiSDR JS file has trailing commas — strip them before parsing
    cleaned = re.sub(r',\s*([}\]])', r'\1', match.group())
    receivers = json.loads(cleaned)
    # Count active, get top locations
    active = [r for r in receivers if r.get('status', '') == 'active']
    locations = {}
    for r in active[:100]:
        loc = r.get('loc', 'Unknown')
        locations[loc] = locations.get(loc, 0) + 1
    top_locs = sorted(locations.items(), key=lambda x: -x[1])[:10]

    print(json.dumps({
        'source': 'kiwisdr',
        'fetched_at': '$ts',
        'total_receivers': len(receivers),
        'active_receivers': len(active),
        'top_locations': [{'location': l, 'count': c} for l, c in top_locs]
    }))
except Exception as e:
    print(json.dumps({'source': 'kiwisdr', 'error': str(e), 'fetched_at': '$ts'}))
" <<< "$raw" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

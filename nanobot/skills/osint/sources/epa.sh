#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="epa"
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

# AirNow current observations for major US cities (no key needed for public feed)
raw=$(curl -sf --max-time 10 \
  "https://www.airnow.gov/rss/aqi-702.xml" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

result=$(python3 -c "
import xml.etree.ElementTree as ET
import json, sys

xml_data = sys.stdin.read()
try:
    root = ET.fromstring(xml_data)
    items = []
    for item in root.findall('.//item')[:10]:
        items.append({
            'title': (item.find('title').text or '') if item.find('title') is not None else '',
            'description': (item.find('description').text or '')[:300] if item.find('description') is not None else '',
            'link': (item.find('link').text or '') if item.find('link') is not None else '',
            'pubDate': (item.find('pubDate').text or '') if item.find('pubDate') is not None else ''
        })
    print(json.dumps({
        'source': 'epa',
        'fetched_at': '$ts',
        'count': len(items),
        'data': items
    }))
except Exception as e:
    print(json.dumps({'source': 'epa', 'error': str(e), 'fetched_at': '$ts'}))
" <<< "$raw" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

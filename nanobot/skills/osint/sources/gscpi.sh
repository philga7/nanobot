#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="gscpi"
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
  "https://www.newyorkfed.org/medialibrary/research/interactives/data/gscpi_data.csv" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

# Parse CSV: take last 12 rows
result=$(python3 -c "
import csv, json, sys, io

data = sys.stdin.read()
reader = csv.DictReader(io.StringIO(data))
rows = list(reader)
recent = rows[-12:] if len(rows) > 12 else rows
# Normalize field names
clean = []
for r in recent:
    entry = {}
    for k, v in r.items():
        entry[k.strip()] = v.strip() if v else ''
    clean.append(entry)
print(json.dumps({
    'source': 'gscpi',
    'fetched_at': '$ts',
    'count': len(clean),
    'readings': clean
}))
" <<< "$raw" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"CSV parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

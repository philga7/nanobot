#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="opensky"
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

OPENSKY_URL="https://opensky-network.org/api/states/all?lamin=25&lomin=-130&lamax=50&lomax=-60"

raw=$(curl -sf --max-time 15 "$OPENSKY_URL" 2>/dev/null) || {
  # Single retry after 3s backoff (OpenSky has intermittent availability)
  sleep 3
  raw=$(curl -sf --max-time 15 "$OPENSKY_URL" 2>/dev/null) || {
    result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed or rate limited (after retry)\",\"fetched_at\":\"${ts}\"}"
    echo "$result" | tee "$CACHE_FILE"
    exit 0
  }
}

result=$(echo "$raw" | jq -c --arg ts "$ts" '{
  source: "opensky",
  fetched_at: $ts,
  time: .time,
  count: ([(.states // [])[] | select(.[7] != null)] | length),
  aircraft: [([(.states // [])[] | select(.[7] != null)] | sort_by(-.[7]))[:20][] | {
    icao24: .[0],
    callsign: (.[1] // "" | gsub("\\s+$"; "")),
    origin_country: .[2],
    longitude: .[5],
    latitude: .[6],
    altitude_m: .[7],
    velocity_ms: .[9]
  }]
}' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

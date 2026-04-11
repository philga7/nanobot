#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="noaa"
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
  -H "User-Agent: nanobot-osint/1.0 (contact@nanobot.local)" \
  -H "Accept: application/geo+json" \
  "https://api.weather.gov/alerts/active?severity=Extreme,Severe" 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"API request failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

result=$(echo "$raw" | jq -c --arg ts "$ts" '
  def ring_centroid(ring):
    (ring | map(select(length >= 2)) | . as $r
    | if ($r | length) == 0 then [null, null]
      else
        [ ($r | map(.[0]) | add / ($r | length)),
          ($r | map(.[1]) | add / ($r | length)) ]
      end);
  def geom_centroid($g):
    if $g == null or ($g | type) != "object" then [null, null]
    elif $g.type == "Point" then [$g.coordinates[0], $g.coordinates[1]]
    elif $g.type == "Polygon" then ring_centroid($g.coordinates[0])
    elif $g.type == "MultiPolygon" then ring_centroid($g.coordinates[0][0])
    else [null, null] end;
  {
    source: "noaa",
    fetched_at: $ts,
    count: (.features // [] | length),
    alerts: [(.features // [])[:15][] | geom_centroid(.geometry) as $c | {
      headline: .properties.headline,
      severity: .properties.severity,
      event: .properties.event,
      area: .properties.areaDesc,
      onset: .properties.onset,
      expires: .properties.expires,
      status: .properties.status,
      centroid_lon: $c[0],
      centroid_lat: $c[1]
    }]
  }
' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

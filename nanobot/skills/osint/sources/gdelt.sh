#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="gdelt"
CACHE_FILE="${CACHE_DIR}/${SOURCE}.json"
CACHE_MAX_AGE=900

# GDELT DOC 2.0 — ArtList (headlines + URLs). Tune without editing the script:
#   GDELT_DOC_QUERY   Full-text query (default below; spaces OK, jq URI-encodes).
#   GDELT_DOC_MAXRECORDS  Cap 1–250 (default 25). Public endpoint rate-limits ~1 req / 5s per IP.
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

# GDELT requires OR-clauses to be wrapped in parentheses.
GDELT_DOC_QUERY_DEFAULT='(conflict OR crisis OR military OR war OR tensions OR deployment OR exercise OR sanctions OR airstrike OR border OR alliance OR indopacific OR philippines OR "south china sea")'
GDELT_DOC_QUERY="${GDELT_DOC_QUERY:-$GDELT_DOC_QUERY_DEFAULT}"
GDELT_DOC_MAXRECORDS="${GDELT_DOC_MAXRECORDS:-25}"
if ! [[ "$GDELT_DOC_MAXRECORDS" =~ ^[0-9]+$ ]] || (( GDELT_DOC_MAXRECORDS < 1 || GDELT_DOC_MAXRECORDS > 250 )); then
  GDELT_DOC_MAXRECORDS=25
fi

query_enc="$(printf '%s' "$GDELT_DOC_QUERY" | jq -sRr @uri 2>/dev/null || printf '%s' "$GDELT_DOC_QUERY" | sed 's/ /%20/g')"

GDELT_URL="https://api.gdeltproject.org/api/v2/doc/doc?query=${query_enc}&mode=ArtList&maxrecords=${GDELT_DOC_MAXRECORDS}&format=json&sort=DateDesc"

# GDELT rate-limits to ~1 request per 5 seconds per IP — retry with backoff
http_code="000"
for attempt in 1 2 3; do
  http_code=$(curl -s -o /tmp/gdelt_raw.json -w "%{http_code}" --max-time 25 "$GDELT_URL" 2>/dev/null) || http_code="000"
  if [[ "$http_code" == "200" ]]; then
    if jq -e 'type == "object" and (.articles | type == "array")' /tmp/gdelt_raw.json >/dev/null 2>&1; then
      break
    fi
    body="$(head -c 300 /tmp/gdelt_raw.json 2>/dev/null | tr '"' "'" | tr '\n' ' ' || true)"
    if [[ -n "$body" ]] && [[ "$body" == *"limit requests"* ]]; then
      http_code="429"
    else
      http_code="422"
    fi
  fi
  [[ "$attempt" -lt 3 ]] && sleep 6
done

if [[ "$http_code" != "200" ]]; then
  body=$(head -c 200 /tmp/gdelt_raw.json 2>/dev/null | tr '"' "'" || echo "")
  result="{\"source\":\"${SOURCE}\",\"error\":\"HTTP ${http_code}\",\"detail\":\"${body}\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  rm -f /tmp/gdelt_raw.json
  exit 0
fi

raw=$(cat /tmp/gdelt_raw.json)
rm -f /tmp/gdelt_raw.json

result=$(echo "$raw" | jq -c --arg ts "$ts" --arg q "$GDELT_DOC_QUERY" --argjson cap "$GDELT_DOC_MAXRECORDS" '
  ($cap | if type == "number" then . elif type == "string" then (tonumber? // 25) else 25 end) as $lim
  | (.articles // []) as $arts
  | {
      source: "gdelt",
      fetched_at: $ts,
      query: $q,
      maxrecords: $lim,
      count: ($arts | length),
      articles: [
        $arts[0:$lim][]
        | {
            title,
            url,
            seendate,
            domain,
            language,
            excerpt: ((.excerpt // .snippet // "") | if . == "" then null else . end)
          }
      ]
    }
' 2>/dev/null) || {
  result="{\"source\":\"${SOURCE}\",\"error\":\"JSON parse failed\",\"fetched_at\":\"${ts}\"}"
  echo "$result" | tee "$CACHE_FILE"
  exit 0
}

echo "$result" | tee "$CACHE_FILE"

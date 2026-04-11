#!/usr/bin/env bash
# Spot gold/silver via https://api.gold-api.com (free /price/*, no key).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="gold_api"
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
utc_day="$(date -u +%Y-%m-%d)"

prev_json="{}"
[[ -f "$CACHE_FILE" ]] && prev_json="$(cat "$CACHE_FILE" 2>/dev/null || echo "{}")"

xau_raw="$(curl -sf --max-time 10 "https://api.gold-api.com/price/XAU" 2>/dev/null || echo "{}")"
xag_raw="$(curl -sf --max-time 10 "https://api.gold-api.com/price/XAG" 2>/dev/null || echo "{}")"

result="$(
  jq -nc \
    --arg ts "$ts" \
    --arg day "$utc_day" \
    --argjson prev "$prev_json" \
    --argjson xau "$xau_raw" \
    --argjson xag "$xag_raw" \
    '
    def asset(sym; inp):
      (inp
        | if type == "object" and (.price != null) then .
          else {error: "fetch failed"} end) as $r
      | ($prev.assets // {})[sym] // {} as $p
      | ($p.day // "") as $pday
      | ($p.day_base // null) as $pb
      | (if $pday != $day or $pb == null then ($r.price // 0) else $pb end) as $base
      | ($r.price // 0) as $px
      | (if ($base | type) == "number" and $base > 0
         then (($px - $base) / $base * 100)
         else 0 end) as $ch
      | {
          symbol: sym,
          name: ($r.name // sym),
          price: $px,
          currency: ($r.currency // "USD"),
          day: $day,
          day_base: $base,
          change_pct_day: $ch,
          updated_at: ($r.updatedAt // "")
        };

    {
      source: "gold_api",
      fetched_at: $ts,
      count: (if ($xau.price != null) and ($xag.price != null) then 2 elif ($xau.price != null) or ($xag.price != null) then 1 else 0 end),
      assets: {
        XAU: asset("XAU"; $xau),
        XAG: asset("XAG"; $xag)
      }
    }
    ' 2>/dev/null
)" || result="{\"source\":\"${SOURCE}\",\"error\":\"jq failed\",\"fetched_at\":\"${ts}\"}"

echo "$result" | tee "$CACHE_FILE"

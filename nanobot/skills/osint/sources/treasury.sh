#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="treasury"
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

rates=$(curl -sf --max-time 10 \
  "https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v2/accounting/od/avg_interest_rates?sort=-record_date&page[size]=10" 2>/dev/null) || rates="{}"

debt=$(curl -sf --max-time 10 \
  "https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v2/accounting/od/debt_to_penny?sort=-record_date&page[size]=5" 2>/dev/null) || debt="{}"

rates_data=$(echo "$rates" | jq -c '[(.data // [])[:10][] | {record_date, security_desc, avg_interest_rate_amt}]' 2>/dev/null) || rates_data="[]"
debt_data=$(echo "$debt" | jq -c '[(.data // [])[:5][] | {record_date, tot_pub_debt_out_amt, intragov_hold_amt}]' 2>/dev/null) || debt_data="[]"

result=$(jq -nc --arg ts "$ts" --argjson rates "$rates_data" --argjson debt "$debt_data" '{
  source: "treasury",
  fetched_at: $ts,
  interest_rates: $rates,
  debt: $debt
}')

echo "$result" | tee "$CACHE_FILE"

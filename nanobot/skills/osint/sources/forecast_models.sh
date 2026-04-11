#!/usr/bin/env bash
# Multi-model daily outlook via Open-Meteo (ECMWF, GFS, NAM CONUS).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="forecast_models"
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

# Override with OSINT_FORECAST_CITIES_JSON='[{"name":"...","lat":34.1,"lon":-83.5},...]'
if [[ -n "${OSINT_FORECAST_CITIES_JSON:-}" ]]; then
  cities_json="$OSINT_FORECAST_CITIES_JSON"
else
  cities_json='[{"name":"Jefferson, GA","lat":34.12,"lon":-83.58},{"name":"Dahlonega, GA","lat":34.53,"lon":-83.98},{"name":"Statesboro, GA","lat":32.45,"lon":-81.78}]'
fi

# Imperial for US weather desk (Open-Meteo: °F and mph).
daily_params="daily=temperature_2m_max,temperature_2m_min,precipitation_probability_mean,wind_speed_10m_max&forecast_days=4&temperature_unit=fahrenheit&wind_speed_unit=mph"

model_id() {
  case "$1" in
    ECMWF) echo "ecmwf_ifs" ;;
    GFS) echo "gfs_global" ;;
    NAM) echo "ncep_nam_conus" ;;
    *) echo "" ;;
  esac
}

merged="$(echo "$cities_json" | jq -c '[.[] | {name, latitude: .lat, longitude: .lon}]' 2>/dev/null)" || merged="[]"

rows=()
while IFS= read -r city_line; do
  [[ -z "$city_line" ]] && continue
  nm="$(echo "$city_line" | jq -r '.name')"
  lat="$(echo "$city_line" | jq -r '.latitude')"
  lon="$(echo "$city_line" | jq -r '.longitude')"
  mjson="{}"
  for label in ECMWF GFS NAM; do
    mid="$(model_id "$label")"
    [[ -z "$mid" ]] && continue
    raw="$(curl -sf --max-time 15 \
      "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&models=${mid}&${daily_params}" 2>/dev/null || echo "{}")"
    slice="$(
      echo "$raw" | jq -c --arg lab "$label" '{
        model: $lab,
        daily: (.daily // {}),
        daily_units: (.daily_units // {})
      }' 2>/dev/null || echo "{}"
    )"
    mjson="$(echo "$mjson" | jq -c --argjson add "$slice" --arg lab "$label" '. + {($lab): $add}')"
  done
  row="$(jq -nc --arg name "$nm" --arg lat "$lat" --arg lon "$lon" --argjson models "$mjson" \
    '{name: $name, latitude: ($lat | tonumber), longitude: ($lon | tonumber), models: $models}')"
  rows+=("$row")
done < <(echo "$merged" | jq -c '.[]')

cities_out="[]"
for r in "${rows[@]:-}"; do
  cities_out="$(echo "$cities_out" | jq -c --argjson x "$r" '. + [$x]')"
done

result="$(jq -nc --arg ts "$ts" --argjson cities "$cities_out" '{
  source: "forecast_models",
  fetched_at: $ts,
  count: ($cities | length),
  cities: $cities
}')"

echo "$result" | tee "$CACHE_FILE"

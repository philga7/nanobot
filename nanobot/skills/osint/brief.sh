#!/usr/bin/env bash
# OSINT Briefing Orchestrator
# Three-layer intelligence pipeline:
#   Layer 1: API sources  (skill's own sources/ scripts)
#   Layer 2: RSS feeds    (~/.wrenvps/intel/sources/fetch-rss.sh)
#   Layer 3: Twitter/X   (~/.wrenvps/intel/sources/fetch-twitter.sh via bird-api)
#
# Usage: bash brief.sh [--force] [--desk NAME]
#   --force  Force-refresh all sources before briefing
#   --desk   Desk id from topics.json → desks.<id> (default: intel). When desks
#            are configured, only that desk's API sources are refreshed and
#            only its RSS/Twitter slugs are included in the JSON output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_DIR="${SCRIPT_DIR}/sources"
CACHE_DIR="${SCRIPT_DIR}/cache"
mkdir -p "$CACHE_DIR"

# Intel pipeline paths
INTEL_DIR="${HOME}/.wrenvps/intel"
INTEL_FETCH_ALL="${INTEL_DIR}/sources/fetch-all.sh"
INTEL_FETCH_RSS="${INTEL_DIR}/sources/fetch-rss.sh"
INTEL_FETCH_TWITTER="${INTEL_DIR}/sources/fetch-twitter.sh"
INTEL_CACHE_RSS="${INTEL_DIR}/cache/rss"
INTEL_CACHE_TWITTER="${INTEL_DIR}/cache/twitter"
INTEL_TOPICS="${INTEL_DIR}/config/topics.json"
INTEL_SOURCES_CFG="${INTEL_DIR}/config/sources.json"
INTEL_HISTORY="${INTEL_DIR}/history/news_history.json"

# API keys: legacy ~/.wrenvps/osint/.env first, then ~/.wrenvps/intel/config/.env (canonical overrides)
for OSINT_ENV in "${HOME}/.wrenvps/osint/.env" "${HOME}/.wrenvps/intel/config/.env"; do
  if [[ -f "$OSINT_ENV" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$OSINT_ENV"
    set +a
  fi
done

FLAG=""
DESK="${OSINT_DESK:-intel}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FLAG="--force"
      shift
      ;;
    --desk)
      DESK="${2:-intel}"
      shift 2
      ;;
    *)
      echo "brief.sh: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

desk_api_json="[]"
desk_rss_json="[]"
desk_tw_json="[]"
desk_json="{}"
desk_api_len=0

if [[ -f "$INTEL_TOPICS" ]] && command -v jq >/dev/null 2>&1; then
  if jq -e --arg d "$DESK" '.desks != null and (.desks | has($d))' "$INTEL_TOPICS" >/dev/null 2>&1; then
    desk_json="$(jq -c --arg d "$DESK" '.desks[$d]' "$INTEL_TOPICS" 2>/dev/null || echo "{}")"
    desk_api_json="$(echo "$desk_json" | jq -c '(.sources.api // []) | map(ascii_downcase | gsub("-"; "_"))' 2>/dev/null || echo "[]")"
    desk_rss_json="$(echo "$desk_json" | jq -c '(.sources.rss // []) | map(ascii_downcase)' 2>/dev/null || echo "[]")"
    desk_tw_json="$(echo "$desk_json" | jq -c '(.sources.twitter // []) | map(ascii_downcase)' 2>/dev/null || echo "[]")"
    desk_api_len="$(echo "$desk_api_json" | jq 'length' 2>/dev/null || echo 0)"
  fi
fi

# Weather desk: center Safecast queries on geo_filter center
if [[ "$DESK" == "weather" ]] && [[ "$(echo "$desk_json" | jq 'has("geo_filter")')" == "true" ]]; then
  c_lat="$(echo "$desk_json" | jq -r '.geo_filter.center[0] // empty')"
  c_lon="$(echo "$desk_json" | jq -r '.geo_filter.center[1] // empty')"
  if [[ -n "$c_lat" && -n "$c_lon" ]]; then
    export OSINT_SAFECAST_LAT="$c_lat"
    export OSINT_SAFECAST_LON="$c_lon"
  fi
fi

TIMEOUT=15
MAX_PARALLEL=10
CACHE_MAX_AGE=900  # 15 minutes

# ---------------------------------------------------------------------------
# Phase 1: API layer — refresh stale OSINT sources (optionally desk-filtered)
# ---------------------------------------------------------------------------
stale=()
fresh=()

api_in_desk() {
  local base="$1"
  local aid
  aid="$(echo "$base" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
  if (( desk_api_len == 0 )); then
    return 0
  fi
  echo "$desk_api_json" | jq -e --arg a "$aid" 'index($a) != null' >/dev/null 2>&1
}

for script in "${SOURCES_DIR}"/*.sh; do
  [[ -x "$script" ]] || continue
  name="$(basename "$script" .sh)"
  api_in_desk "$name" || continue

  cache_file="${CACHE_DIR}/${name}.json"

  if [[ "$FLAG" == "--force" ]]; then
    stale+=("$script")
  elif [[ -f "$cache_file" ]]; then
    file_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if (( file_age < CACHE_MAX_AGE )); then
      fresh+=("$name")
    else
      stale+=("$script")
    fi
  else
    stale+=("$script")
  fi
done

echo "Brief: desk=${DESK} — ${#fresh[@]} API sources cached, ${#stale[@]} stale — refreshing stale sources..." >&2

if [[ ${#stale[@]} -gt 0 ]]; then
  pids=()
  for script in "${stale[@]}"; do
    (
      timeout "$TIMEOUT" bash "$script" --force > /dev/null 2>&1 || true
    ) &
    pids+=($!)

    if (( ${#pids[@]} >= MAX_PARALLEL )); then
      for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done
      pids=()
    fi
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
fi

# ---------------------------------------------------------------------------
# Phase 2: RSS + Twitter layers via intel pipeline (graceful degradation)
# ---------------------------------------------------------------------------
intel_available=false
if [[ -d "$INTEL_DIR" ]]; then
  intel_available=true
fi

if [[ "$intel_available" == "true" ]]; then
  intel_force_flag=""
  [[ "$FLAG" == "--force" ]] && intel_force_flag="--force"
  if [[ -x "$INTEL_FETCH_ALL" ]]; then
    echo "Brief: running intel pipeline fetch-all.sh..." >&2
    timeout 60 bash "$INTEL_FETCH_ALL" $intel_force_flag > /dev/null 2>&1 || true
  elif [[ -x "$INTEL_FETCH_RSS" || -x "$INTEL_FETCH_TWITTER" ]]; then
    rss_pid=""
    twitter_pid=""
    if [[ -x "$INTEL_FETCH_RSS" ]]; then
      echo "Brief: running intel pipeline fetch-rss.sh..." >&2
      timeout 60 bash "$INTEL_FETCH_RSS" $intel_force_flag > /dev/null 2>&1 || true &
      rss_pid=$!
    fi
    if [[ -x "$INTEL_FETCH_TWITTER" ]]; then
      echo "Brief: running intel pipeline fetch-twitter.sh..." >&2
      timeout 30 bash "$INTEL_FETCH_TWITTER" $intel_force_flag > /dev/null 2>&1 || true &
      twitter_pid=$!
    fi
    [[ -n "$rss_pid" ]] && wait "$rss_pid" 2>/dev/null || true
    [[ -n "$twitter_pid" ]] && wait "$twitter_pid" 2>/dev/null || true
  else
    echo "Brief: intel pipeline present but fetch scripts not found — skipping RSS/Twitter layer" >&2
  fi
else
  echo "Brief: intel pipeline not found at ${INTEL_DIR} — skipping RSS/Twitter layer" >&2
fi

# ---------------------------------------------------------------------------
# Phase 3: Load topic weights and tier classification
# ---------------------------------------------------------------------------
priority_topics=()
major_event_keywords=()
tier_mainstream=()
tier_alternative=()
tier_fringe=()

if [[ -f "$INTEL_TOPICS" ]] && command -v jq >/dev/null 2>&1; then
  mapfile -t priority_topics < <(
    jq -r '(.priority_topics // {}) | keys[]' "$INTEL_TOPICS" 2>/dev/null || true
  )
  mapfile -t major_event_keywords < <(
    jq -r '(.major_event_keywords // [])[]' "$INTEL_TOPICS" 2>/dev/null || true
  )
  mapfile -t tier_mainstream < <(
    jq -r '(.source_tier_classification.mainstream // [])[]' "$INTEL_TOPICS" 2>/dev/null || true
  )
  mapfile -t tier_alternative < <(
    jq -r '(.source_tier_classification.alternative // [])[]' "$INTEL_TOPICS" 2>/dev/null || true
  )
  mapfile -t tier_fringe < <(
    jq -r '(.source_tier_classification.fringe // [])[]' "$INTEL_TOPICS" 2>/dev/null || true
  )
fi

# ---------------------------------------------------------------------------
# Phase 4: Collect RSS items
# ---------------------------------------------------------------------------
rss_items_json="[]"
if [[ -d "$INTEL_CACHE_RSS" ]] && command -v jq >/dev/null 2>&1; then
  rss_json_files=("${INTEL_CACHE_RSS}"/*.json)
  if [[ -e "${rss_json_files[0]}" ]]; then
    rss_items_json="$(
      jq -sc '
        [.[]
          | if type == "array" then .[] else . end
          | select(type == "object")
          | if has("items") and (.items | type == "array") then
              . as $feed | $feed.items[] | . + {
                source: (.source // $feed.source // "RSS"),
                category: (.category // $feed.category // null),
                tier: (.tier // $feed.tier // null),
                feed: (.feed // $feed.feed // $feed.source // "RSS")
              }
            else
              .
            end
        ]
      ' "${rss_json_files[@]}" 2>/dev/null || echo "[]"
    )"
    rss_count="$(echo "$rss_items_json" | jq 'length' 2>/dev/null || echo 0)"
    echo "Brief: loaded ${rss_count} RSS items (pre-filter)" >&2
  fi
fi

desk_rss_len="$(echo "$desk_rss_json" | jq 'length' 2>/dev/null || echo 0)"
if (( desk_rss_len > 0 )); then
  rss_items_json="$(
    echo "$rss_items_json" | jq -c --argjson allow "$desk_rss_json" '
      def norm: ascii_downcase | gsub("-"; "");
      map(select(
        (.feed // .source // .id // "" | tostring | norm) as $f
        | ($allow | map(norm) | index($f) != null)
      ))
    ' 2>/dev/null || echo "[]"
  )"
fi

# Merge GDELT DOC headlines into the RSS stream so deliver.sh topic-weights
# and RSS FEEDS ranking apply (desk must list gdelt under sources.api).
if echo "$desk_api_json" | jq -e 'index("gdelt") != null' >/dev/null 2>&1; then
  GDELT_CACHE="${CACHE_DIR}/gdelt.json"
  if [[ -f "$GDELT_CACHE" ]] && ! jq -e 'has("error") and (.error != null and .error != "")' "$GDELT_CACHE" >/dev/null 2>&1; then
    gdelt_as_rss="$(
      jq -c '
        [ (.articles // [])[]
          | select((.title // "") != "" or (.url // "") != "")
          | (.seendate // "" | tostring) as $sd
          | ($sd
            | if test("^[0-9]{8}T[0-9]{6}Z$") then
                .[0:4] + "-" + .[4:6] + "-" + .[6:8] + "T" + .[9:11] + ":" + .[11:13] + ":" + .[13:15] + "Z"
              elif test("^[0-9]{14}$") then
                .[0:4] + "-" + .[4:6] + "-" + .[6:8] + "T" + .[8:10] + ":" + .[10:12] + ":" + .[12:14] + "Z"
              elif test("^[0-9]{8}$") then
                .[0:4] + "-" + .[4:6] + "-" + .[6:8] + "T12:00:00Z"
              else $sd end
            ) as $pub
          | {
              title: (.title // ""),
              url: (.url // ""),
              source: "GDELT",
              feed: "gdelt",
              category: "geopolitics",
              tier: null,
              published: (
                if ($pub | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) then $pub else null end
              ),
              description: (
                [
                  (.domain // empty | select(. != "")),
                  (.language // empty | select(. != "") | "[" + . + "]")
                ] | join(" ") | if . == "" then null else . end
              )
            }
        ]
      ' "$GDELT_CACHE" 2>/dev/null || echo "[]"
    )"
    rss_items_json="$(
      jq -n --argjson r "$rss_items_json" --argjson g "${gdelt_as_rss:-[]}" '$r + $g' 2>/dev/null || echo "$rss_items_json"
    )"
    gct="$(echo "${gdelt_as_rss:-[]}" | jq 'length' 2>/dev/null || echo 0)"
    echo "Brief: merged ${gct} GDELT articles into RSS stream" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Phase 5: Collect Twitter items
# ---------------------------------------------------------------------------
twitter_items_json="[]"
if [[ -d "$INTEL_CACHE_TWITTER" ]] && command -v jq >/dev/null 2>&1; then
  twitter_json_files=("${INTEL_CACHE_TWITTER}"/*.json)
  if [[ -e "${twitter_json_files[0]}" ]]; then
    twitter_items_json="$(
      jq -sc '
        [.[]
          | if type == "array" then .[] else . end
          | select(type == "object")
        ]
      ' "${twitter_json_files[@]}" 2>/dev/null || echo "[]"
    )"
    twitter_count="$(echo "$twitter_items_json" | jq 'length' 2>/dev/null || echo 0)"
    echo "Brief: loaded ${twitter_count} Twitter items (pre-filter)" >&2
  fi
fi

# Optional global dedup: skip RSS/Twitter rows already recorded in news_history.json.
DEDUP_PY_BRIEF="${SCRIPT_DIR}/sources/dedup.py"
if [[ -x "$DEDUP_PY_BRIEF" ]]; then
  rss_items_json="$(
    echo "$rss_items_json" | jq -c '.[]?' 2>/dev/null | while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      key="$(echo "$row" | jq -r '(.guid // .id // .url // .link // "") | tostring' 2>/dev/null)"
      [[ -n "$key" && "$key" != "" && "$key" != "null" ]] || continue
      chk="$(python3 "$DEDUP_PY_BRIEF" --history "$INTEL_HISTORY" --check "$key" 2>/dev/null || true)"
      [[ "$(printf '%s' "$chk" | tr -d '\r\n')" == "new" ]] && printf '%s\n' "$row"
    done | jq -s '.' 2>/dev/null || echo "$rss_items_json"
  )"
  twitter_items_json="$(
    echo "$twitter_items_json" | jq -c '.[]?' 2>/dev/null | while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      key="$(echo "$row" | jq -r '(.tweet_id // .id // .url // "") | tostring' 2>/dev/null)"
      [[ -n "$key" && "$key" != "" && "$key" != "null" ]] || continue
      chk="$(python3 "$DEDUP_PY_BRIEF" --history "$INTEL_HISTORY" --check "$key" 2>/dev/null || true)"
      [[ "$(printf '%s' "$chk" | tr -d '\r\n')" == "new" ]] && printf '%s\n' "$row"
    done | jq -s '.' 2>/dev/null || echo "$twitter_items_json"
  )"
elif [[ -f "$INTEL_HISTORY" ]] && command -v jq >/dev/null 2>&1; then
  seen_keys="$(
    jq -c '
      to_entries
      | map(
          select(
            (.value.channels // []) | any(. == "#live-feed" or . == "#breaking-news")
          )
          | .key
        )
    ' "$INTEL_HISTORY" 2>/dev/null || echo "[]"
  )"
  if [[ "$seen_keys" != "[]" ]]; then
    rss_items_json="$(
      echo "$rss_items_json" | jq -c --argjson seen "$seen_keys" '
        map(
          . as $r
          | (
              ($r.guid // $r.id // $r.url // $r.link // "")
              | tostring
            ) as $k
          | select(($seen | index($k)) == null)
        )
      ' 2>/dev/null || echo "$rss_items_json"
    )"
    twitter_items_json="$(
      echo "$twitter_items_json" | jq -c --argjson seen "$seen_keys" '
        map(
          . as $t
          | (
              ($t.tweet_id // $t.id // $t.url // "")
              | tostring
            ) as $k
          | select(($seen | index($k)) == null)
        )
      ' 2>/dev/null || echo "$twitter_items_json"
    )"
  fi
fi

desk_tw_len="$(echo "$desk_tw_json" | jq 'length' 2>/dev/null || echo 0)"
if (( desk_tw_len > 0 )); then
  twitter_items_json="$(
    echo "$twitter_items_json" | jq -c --argjson allow "$desk_tw_json" '
      def compact: gsub("-"; "") | gsub("_"; "") | ascii_downcase;
      map(select(
        (.handle // .user // .screen_name // "" | tostring | ltrimstr("@") | compact) as $h
        | ($allow | map(compact) | index($h) != null)
      ))
    ' 2>/dev/null || echo "[]"
  )"
fi

# ---------------------------------------------------------------------------
# Phase 6: Build topic weight index (for synthesis hints in output)
# ---------------------------------------------------------------------------
topic_weights_json="{}"
if [[ -f "$INTEL_TOPICS" ]] && command -v jq >/dev/null 2>&1; then
  topic_weights_json="$(
    jq -c '(.priority_topics // {})' "$INTEL_TOPICS" 2>/dev/null || echo "{}"
  )"
fi

# ---------------------------------------------------------------------------
# Phase 7: Combine all data into single output
# ---------------------------------------------------------------------------
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
current_conditions_json="[]"

if [[ "$DESK" == "weather" ]]; then
  weather_cities_json='[{"name":"Jefferson, GA","lat":34.12,"lon":-83.58},{"name":"Dahlonega, GA","lat":34.53,"lon":-83.98},{"name":"Statesboro, GA","lat":32.45,"lon":-81.78}]'
  rows=()
  while IFS= read -r city; do
    [[ -z "$city" ]] && continue
    city_name="$(echo "$city" | jq -r '.name')"
    city_lat="$(echo "$city" | jq -r '.lat')"
    city_lon="$(echo "$city" | jq -r '.lon')"
    weather_raw="$(
      curl -sf --max-time 15 \
        "https://api.open-meteo.com/v1/forecast?latitude=${city_lat}&longitude=${city_lon}&current=temperature_2m,relative_humidity_2m,apparent_temperature,wind_speed_10m,wind_direction_10m,weather_code,uv_index&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&temperature_unit=fahrenheit&wind_speed_unit=mph" \
        2>/dev/null || echo "{}"
    )"
    weather_row="$(
      echo "$weather_raw" | jq -c --arg name "$city_name" --argjson lat "$city_lat" --argjson lon "$city_lon" '
        def wx_desc($c):
          if $c == 0 then "clear"
          elif ($c == 1 or $c == 2) then "partly cloudy"
          elif $c == 3 then "overcast"
          elif ($c == 45 or $c == 48) then "fog"
          elif ($c >= 51 and $c <= 57) then "drizzle"
          elif ($c >= 61 and $c <= 67) then "rain"
          elif ($c >= 71 and $c <= 77) then "snow"
          elif ($c == 80 or $c == 81 or $c == 82) then "rain showers"
          elif ($c == 85 or $c == 86) then "snow showers"
          elif ($c >= 95 and $c <= 99) then "thunderstorms"
          else "unknown"
          end;
        {
          name: $name,
          latitude: $lat,
          longitude: $lon,
          current: {
            temperature_f: (.current.temperature_2m // null),
            apparent_temperature_f: (.current.apparent_temperature // null),
            humidity_pct: (.current.relative_humidity_2m // null),
            wind_speed_mph: (.current.wind_speed_10m // null),
            wind_direction_deg: (.current.wind_direction_10m // null),
            uv_index: (.current.uv_index // null),
            weather_code: (.current.weather_code // null),
            condition: wx_desc(.current.weather_code // -1),
            observed_at: (.current.time // null)
          },
          daily: {
            high_f: (.daily.temperature_2m_max[0] // null),
            low_f: (.daily.temperature_2m_min[0] // null),
            day: (.daily.time[0] // null)
          }
        }
      ' 2>/dev/null || echo "{}"
    )"
    rows+=("$weather_row")
  done < <(echo "$weather_cities_json" | jq -c '.[]')

  current_conditions_json="[]"
  for row in "${rows[@]:-}"; do
    current_conditions_json="$(
      echo "$current_conditions_json" | jq -c --argjson x "$row" '. + [$x]' 2>/dev/null || echo "$current_conditions_json"
    )"
  done
fi

{
  echo '{'
  echo "  \"briefing_timestamp\": \"${timestamp}\","
  echo "  \"desk\": \"${DESK}\","
  echo '  "sources": {'

  first=true
  for cache_file in "${CACHE_DIR}"/*.json; do
    [[ -f "$cache_file" ]] || continue
    name="$(basename "$cache_file" .json)"
    aid="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
    if (( desk_api_len > 0 )); then
      echo "$desk_api_json" | jq -e --arg a "$aid" 'index($a) != null' >/dev/null 2>&1 || continue
    fi

    if [[ "$first" == "true" ]]; then
      first=false
    else
      echo ','
    fi

    if jq empty "$cache_file" 2>/dev/null; then
      printf '    "%s": ' "$name"
      cat "$cache_file"
    else
      printf '    "%s": {"source":"%s","error":"invalid cache","fetched_at":"%s"}' "$name" "$name" "$timestamp"
    fi
  done

  echo ''
  echo '  },'
  echo "  \"current_conditions\": ${current_conditions_json},"

  echo "  \"rss\": ${rss_items_json},"

  echo "  \"twitter\": ${twitter_items_json},"

  echo "  \"topic_weights\": ${topic_weights_json},"

  source_count=0
  error_count=0
  for cache_file in "${CACHE_DIR}"/*.json; do
    [[ -f "$cache_file" ]] || continue
    name="$(basename "$cache_file" .json)"
    aid="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
    if (( desk_api_len > 0 )); then
      echo "$desk_api_json" | jq -e --arg a "$aid" 'index($a) != null' >/dev/null 2>&1 || continue
    fi
    source_count=$((source_count + 1))
    if jq -e '.error' "$cache_file" > /dev/null 2>&1; then
      error_count=$((error_count + 1))
    fi
  done

  rss_item_count="$(echo "$rss_items_json" | jq 'length' 2>/dev/null || echo 0)"
  twitter_item_count="$(echo "$twitter_items_json" | jq 'length' 2>/dev/null || echo 0)"

  desk_filt_bool=false
  (( desk_api_len > 0 )) && desk_filt_bool=true

  _bt="${OSINT_BRIEFING_TEMPLATE:-}"
  echo "  \"meta\": {"
  echo "    \"desk\": \"${DESK}\","
  echo "    \"desk_api_filtered\": ${desk_filt_bool},"
  echo "    \"total_api_sources\": ${source_count},"
  echo "    \"total_sources\": ${source_count},"
  echo "    \"sources_with_errors\": ${error_count},"
  echo "    \"rss_items\": ${rss_item_count},"
  echo "    \"twitter_items\": ${twitter_item_count},"
  echo "    \"intel_pipeline_available\": ${intel_available},"
  echo "    \"generated_at\": \"${timestamp}\""
  if [[ -n "${_bt}" ]]; then
    echo ",    \"brief_template_requested\": \"${_bt}\""
  fi
  echo '  }'
  echo '}'
}

if (( error_count > 0 )); then
  echo "Brief data ready: desk=${DESK} ${source_count:-0} API sources, ${rss_item_count:-0} RSS items, ${twitter_item_count:-0} tweets (${error_count} API sources with errors)" >&2
else
  echo "Brief data ready: desk=${DESK} ${source_count:-0} API sources, ${rss_item_count:-0} RSS items, ${twitter_item_count:-0} tweets" >&2
fi

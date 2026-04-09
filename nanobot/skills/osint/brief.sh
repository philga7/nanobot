#!/usr/bin/env bash
# OSINT Briefing Orchestrator
# Three-layer intelligence pipeline:
#   Layer 1: API sources  (skill's own sources/ scripts)
#   Layer 2: RSS feeds    (~/.wrenvps/intel/sources/fetch-rss.sh)
#   Layer 3: Twitter/X   (~/.wrenvps/intel/sources/fetch-twitter.sh via bird-api)
#
# Usage: bash brief.sh [--force]
#   --force  Force-refresh all sources before briefing
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

# Source OSINT API keys if .env exists
OSINT_ENV="${HOME}/.wrenvps/osint/.env"
if [[ -f "$OSINT_ENV" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$OSINT_ENV"
  set +a
fi

FLAG="${1:-}"
TIMEOUT=15
MAX_PARALLEL=10
CACHE_MAX_AGE=900  # 15 minutes

# ---------------------------------------------------------------------------
# Phase 1: API layer — refresh stale OSINT sources
# ---------------------------------------------------------------------------
stale=()
fresh=()

for script in "${SOURCES_DIR}"/*.sh; do
  [[ -x "$script" ]] || continue
  name="$(basename "$script" .sh)"
  cache_file="${CACHE_DIR}/${name}.json"

  if [[ "$FLAG" == "--force" ]]; then
    stale+=("$script")
  elif [[ -f "$cache_file" ]]; then
    file_age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if (( file_age < CACHE_MAX_AGE )); then
      fresh+=("$name")
    else
      stale+=("$script")
    fi
  else
    stale+=("$script")
  fi
done

echo "Brief: ${#fresh[@]} API sources cached, ${#stale[@]} stale — refreshing stale sources..." >&2

if [[ ${#stale[@]} -gt 0 ]]; then
  pids=()
  for script in "${stale[@]}"; do
    name="$(basename "$script" .sh)"
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
    # Run individual layers if fetch-all.sh not present
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
  # Extract priority topic keys (array of strings)
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
        ]
      ' "${rss_json_files[@]}" 2>/dev/null || echo "[]"
    )"
    rss_count="$(echo "$rss_items_json" | jq 'length' 2>/dev/null || echo 0)"
    echo "Brief: loaded ${rss_count} RSS items" >&2
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
    echo "Brief: loaded ${twitter_count} Twitter items" >&2
  fi
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

{
  echo '{'
  echo "  \"briefing_timestamp\": \"${timestamp}\","
  echo '  "sources": {'

  first=true
  for cache_file in "${CACHE_DIR}"/*.json; do
    [[ -f "$cache_file" ]] || continue
    name="$(basename "$cache_file" .json)"

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

  # RSS layer
  echo "  \"rss\": ${rss_items_json},"

  # Twitter layer
  echo "  \"twitter\": ${twitter_items_json},"

  # Topic weights (passed through for LLM synthesis)
  echo "  \"topic_weights\": ${topic_weights_json},"

  # Count sources
  source_count=0
  error_count=0
  for cache_file in "${CACHE_DIR}"/*.json; do
    [[ -f "$cache_file" ]] || continue
    source_count=$((source_count + 1))
    if jq -e '.error' "$cache_file" > /dev/null 2>&1; then
      error_count=$((error_count + 1))
    fi
  done

  rss_item_count="$(echo "$rss_items_json" | jq 'length' 2>/dev/null || echo 0)"
  twitter_item_count="$(echo "$twitter_items_json" | jq 'length' 2>/dev/null || echo 0)"

  echo "  \"meta\": {"
  echo "    \"total_api_sources\": ${source_count},"
  echo "    \"total_sources\": ${source_count},"
  echo "    \"sources_with_errors\": ${error_count},"
  echo "    \"rss_items\": ${rss_item_count},"
  echo "    \"twitter_items\": ${twitter_item_count},"
  echo "    \"intel_pipeline_available\": ${intel_available},"
  echo "    \"generated_at\": \"${timestamp}\""
  echo '  }'
  echo '}'
}

if (( error_count > 0 )); then
  echo "Brief data ready: ${source_count:-0} API sources, ${rss_item_count:-0} RSS items, ${twitter_item_count:-0} tweets (${error_count} API sources with errors)" >&2
else
  echo "Brief data ready: ${source_count:-0} API sources, ${rss_item_count:-0} RSS items, ${twitter_item_count:-0} tweets" >&2
fi

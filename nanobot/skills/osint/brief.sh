#!/usr/bin/env bash
# OSINT Briefing Orchestrator
# 1. Check all source caches for freshness
# 2. Fetch stale sources in parallel (15s timeout)
# 3. Load all cached data
# 4. Output combined JSON for LLM synthesis
#
# Usage: bash brief.sh [--force]
#   --force  Force-refresh all sources before briefing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_DIR="${SCRIPT_DIR}/sources"
CACHE_DIR="${SCRIPT_DIR}/cache"
mkdir -p "$CACHE_DIR"

FLAG="${1:-}"
TIMEOUT=15
MAX_PARALLEL=10
CACHE_MAX_AGE=900  # 15 minutes

# --- Phase 1: Identify stale sources and refresh them ---
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

echo "Brief: ${#fresh[@]} cached, ${#stale[@]} stale — refreshing stale sources..." >&2

# Refresh stale sources in parallel
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

# --- Phase 2: Combine all cached data ---
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build combined JSON output
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

    # Read cached data, validate it's JSON
    if jq empty "$cache_file" 2>/dev/null; then
      printf '    "%s": ' "$name"
      cat "$cache_file"
    else
      printf '    "%s": {"source":"%s","error":"invalid cache","fetched_at":"%s"}' "$name" "$name" "$timestamp"
    fi
  done

  echo ''
  echo '  },'

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

  echo "  \"meta\": {"
  echo "    \"total_sources\": ${source_count},"
  echo "    \"sources_with_errors\": ${error_count},"
  echo "    \"generated_at\": \"${timestamp}\""
  echo '  }'
  echo '}'
}

echo "Brief data ready: ${source_count:-0} sources combined" >&2

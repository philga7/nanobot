#!/usr/bin/env bash
# Refresh all OSINT source caches in parallel.
# Usage: bash refresh-all.sh [--force]
#   --force  Bypass cache and fetch all sources fresh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_DIR="${SCRIPT_DIR}/sources"
CACHE_DIR="${SCRIPT_DIR}/cache"
mkdir -p "$CACHE_DIR"

# API keys: legacy osint/.env first, then intel/config/.env (canonical overrides)
for OSINT_ENV in "${HOME}/.wrenvps/osint/.env" "${HOME}/.wrenvps/intel/config/.env"; do
  if [[ -f "$OSINT_ENV" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$OSINT_ENV"
    set +a
  fi
done

FLAG="${1:-}"
TIMEOUT=15  # Max seconds per source fetch
MAX_PARALLEL=10

# Collect all source scripts
scripts=()
for script in "${SOURCES_DIR}"/*.sh; do
  [[ -x "$script" ]] || continue
  scripts+=("$script")
done

if [[ ${#scripts[@]} -eq 0 ]]; then
  echo '{"error":"no source scripts found","sources_dir":"'"${SOURCES_DIR}"'"}' >&2
  exit 1
fi

echo "Refreshing ${#scripts[@]} OSINT sources (max ${TIMEOUT}s each, ${MAX_PARALLEL} parallel)..." >&2

# Run all source scripts in parallel with timeout
pids=()
names=()
ok=0
fail=0

for script in "${scripts[@]}"; do
  name="$(basename "$script" .sh)"
  names+=("$name")

  (
    if timeout "$TIMEOUT" bash "$script" $FLAG > /dev/null 2>&1; then
      echo "ok   $name" >&2
    else
      echo "FAIL $name" >&2
      exit 1
    fi
  ) &
  pids+=($!)

  # Throttle parallelism
  if (( ${#pids[@]} >= MAX_PARALLEL )); then
    for pid in "${pids[@]}"; do
      if wait "$pid" 2>/dev/null; then
        ok=$((ok + 1))
      else
        fail=$((fail + 1))
      fi
    done
    pids=()
  fi
done

# Wait for remaining
for pid in "${pids[@]}"; do
  if wait "$pid" 2>/dev/null; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done

# Post-run: check cached JSON for sources that exited 0 but have errors in data
data_errors=0
for script in "${scripts[@]}"; do
  name="$(basename "$script" .sh)"
  cache_file="${CACHE_DIR}/${name}.json"
  if [[ -f "$cache_file" ]] && jq -e '.error' "$cache_file" > /dev/null 2>&1; then
    data_errors=$((data_errors + 1))
  fi
done

if (( data_errors > 0 )); then
  echo "Refresh complete: ${ok} ok (${data_errors} with data errors), ${fail} failed (of ${#scripts[@]} total)" >&2
else
  echo "Refresh complete: ${ok} ok, ${fail} failed (of ${#scripts[@]} total)" >&2
fi

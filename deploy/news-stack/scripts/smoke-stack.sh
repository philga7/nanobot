#!/usr/bin/env bash
# Best-effort HTTP checks for services that are up (from the host, loopback ports).
# Run from deploy/news-stack after `docker compose ... up`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

QH="${QDRANT_HTTP_PORT:-6333}"
CR="${CRUCIX_PORT:-3117}"
OF="${OFFICE_PORT:-8082}"

pass=0
fail=0

probe() {
  local name="$1" url="$2"
  if curl -sf --connect-timeout 2 --max-time 5 "$url" >/dev/null 2>&1; then
    echo "ok   $name  $url"
    pass=$((pass + 1))
  else
    echo "---- $name  $url  (not reachable — service may be down or not started yet)"
    fail=$((fail + 1))
  fi
}

echo "News stack smoke (host ports from .env or defaults)"
probe "qdrant" "http://127.0.0.1:${QH}/"
probe "crucix" "http://127.0.0.1:${CR}/api/health"
probe "office" "http://127.0.0.1:${OF}/health"
echo "Summary: ${pass} reachable, ${fail} skipped/failed"
exit 0

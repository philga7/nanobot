#!/usr/bin/env bash
# Clone upstream repos into ./vendor for docker compose --profile full.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${ROOT}/vendor"
mkdir -p "${VENDOR}"

clone_or_update() {
  local url="$1"
  local name="$2"
  local branch="${3:-master}"
  local target="${VENDOR}/${name}"
  if [[ -d "${target}/.git" ]]; then
    git -C "${target}" fetch --depth 1 origin "${branch}"
    git -C "${target}" checkout "${branch}"
    git -C "${target}" pull --ff-only origin "${branch}" || true
  else
    git clone --depth 1 --branch "${branch}" "${url}" "${target}"
  fi
}

clone_or_update "https://github.com/calesthio/Crucix.git" "crucix" "master"
clone_or_update "https://github.com/wangziqi06/724-office.git" "724-office" "master"

echo "Vendored repos under ${VENDOR}. Next:"
echo "  cp vendor/crucix/.env.example vendor/crucix/.env   # Crucix: edit keys"
echo "  cp vendor/724-office/config.example.json vendor/724-office/config.json"
echo "  docker compose --profile full up -d --build"

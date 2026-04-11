#!/usr/bin/env bash
# Intel layer: fetch X timelines via bird-api and write ~/.wrenvps/intel/cache/twitter/<account>.json
#
# Deploy: install executable at ~/.wrenvps/intel/sources/fetch-twitter.sh (same path brief.sh uses).
#
# Reads handles from ~/.wrenvps/intel/config/sources.json:
#   .twitter.accounts | keys[]   and/or   .twitter.handles[]   (strings, with or without @)
#
# Env:
#   BIRD_API_URL   Base URL (default http://127.0.0.1:18791)
#   INTEL_DIR      Intel root (default ~/.wrenvps/intel)
#
# Raw HTTP bodies are written to a temp file and parsed in Python (no shell interpolation of JSON).
# Parser logic matches ~/.wrenvps/intel/sources/fetch-twitter.sh: JSON unwrap, ─{3,} blocks, line filters.
set -euo pipefail

INTEL_DIR="${INTEL_DIR:-${HOME}/.wrenvps/intel}"
SOURCES_CFG="${INTEL_DIR}/config/sources.json"
CACHE_DIR="${INTEL_DIR}/cache/twitter"
BIRD_API_URL="${BIRD_API_URL:-http://127.0.0.1:18791}"
CACHE_MAX_AGE="${CACHE_MAX_AGE:-900}"

FORCE=false
if [[ "${1:-}" == "--force" ]]; then
  FORCE=true
fi

mkdir -p "$CACHE_DIR"

if [[ ! -f "$SOURCES_CFG" ]]; then
  echo "fetch-twitter: missing ${SOURCES_CFG}" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "fetch-twitter: jq required" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "fetch-twitter: curl required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "fetch-twitter: python3 required" >&2
  exit 1
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mapfile -t HANDLES < <(
  jq -r '
    [
      ((.twitter.accounts // {}) | keys[]),
      ((.twitter.handles // [])[]? | strings)
    ]
    | map(gsub("^@"; ""))
    | map(select(length > 0))
    | unique
    | .[]
  ' "$SOURCES_CFG" 2>/dev/null || true
)

if [[ ${#HANDLES[@]} -eq 0 ]]; then
  echo "fetch-twitter: no twitter handles in ${SOURCES_CFG} (.twitter.accounts or .twitter.handles)" >&2
  exit 0
fi

for h in "${HANDLES[@]}"; do
  [[ -z "$h" ]] && continue
  safe="${h//[^A-Za-z0-9_-]/_}"
  out="${CACHE_DIR}/${safe}.json"

  if [[ "$FORCE" != true ]] && [[ -f "$out" ]]; then
    now="$(date +%s)"
    mtime=0
    if stat -f %m "$out" >/dev/null 2>&1; then
      mtime="$(stat -f %m "$out")"
    elif stat -c %Y "$out" >/dev/null 2>&1; then
      mtime="$(stat -c %Y "$out")"
    fi
    if (( now - mtime < CACHE_MAX_AGE )); then
      continue
    fi
  fi

  enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$h")"
  url="${BIRD_API_URL%/}/timeline?handle=${enc}&limit=20"

  tmp_raw="$(mktemp "${TMPDIR:-/tmp}/bird_raw.XXXXXX")"
  if ! curl -fsS --max-time 60 "$url" >"$tmp_raw" 2>/dev/null; then
    rm -f "$tmp_raw"
    jq -nc --arg h "@${h}" --arg fts "$ts" \
      '{error:"curl_failed",handle:$h,fetched_at:$fts}' >"$out"
    continue
  fi

  if ! python3 - "$tmp_raw" "$h" "$ts" >"${out}.new" 2>/dev/null <<'PY'
import json
import pathlib
import re
import sys


def main() -> None:
    path, clean_handle, fts = sys.argv[1], sys.argv[2].lstrip("@"), sys.argv[3]
    raw = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")

    # If bird-api returned JSON, extract the .output field first (matches VPS fetch-twitter.sh).
    if raw.strip().startswith("{"):
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                raw = str(parsed.get("output", raw))
        except json.JSONDecodeError:
            pass

    # Strip one leading @Handle (Display Name): prefix (handle stored separately on each item).
    raw = re.sub(r"^\s*@[\w]+\s*\([^)]*\):\s*", "", raw)

    # Bird-api returns text blocks separated by three or more ─ (U+2500).
    blocks = re.split(r"\u2500{3,}", raw)
    items: list[dict] = []
    for block in blocks:
        block = block.strip()
        if not block:
            continue
        lines = block.split("\n")
        text_lines: list[str] = []
        link = ""
        for line in lines:
            line = line.strip()
            if not line:
                continue
            if line.startswith("VIDEO:") or line.startswith("PHOTO:") or line.startswith("QT:"):
                continue
            m_url = re.match(r"^url:\s*(\S+)", line, re.I)
            if m_url:
                link = m_url.group(1).strip()
                continue
            if re.match(r"^https?://", line):
                if not link:
                    link = line
                continue
            if re.match(r"^\w{3} \w{3} \d{1,2}", line) and len(line) < 40:
                continue
            text_lines.append(line)
        if text_lines:
            item: dict = {"text": " ".join(text_lines)[:500], "handle": clean_handle}
            if link:
                item["url"] = link
            items.append(item)
        if len(items) >= 15:
            break

    acct = {
        "handle": f"@{clean_handle}",
        "items": items,
        "source": "twitter",
        "fetched_at": fts,
    }
    out_obj = {"fetched_at": fts, "accounts": {clean_handle.lower(): acct}}
    print(json.dumps(out_obj, ensure_ascii=False))


if __name__ == "__main__":
    main()
PY
  then
    rm -f "$tmp_raw" "${out}.new"
    jq -nc --arg h "@${h}" --arg fts "$ts" \
      '{error:"parse_failed",handle:$h,fetched_at:$fts}' >"$out"
    continue
  fi
  rm -f "$tmp_raw"
  mv "${out}.new" "$out"
done

echo "fetch-twitter: refreshed cache under ${CACHE_DIR}" >&2

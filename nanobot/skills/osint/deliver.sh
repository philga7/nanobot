#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIEF_SCRIPT="${SCRIPT_DIR}/brief.sh"
DEFAULT_ENV="${HOME}/.wrenvps/osint/.env"

FORCE=false
DRY_RUN=false
TEMPLATE="${OSINT_BRIEFING_TEMPLATE:-intelSignal}"
CHANNEL_ID="${OSINT_BRIEFING_SLACK_CHANNEL_ID:-C0AGWCQ1ZDE}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    --template)
      TEMPLATE="${2:-$TEMPLATE}"
      shift
      ;;
    --channel-id)
      CHANNEL_ID="${2:-$CHANNEL_ID}"
      shift
      ;;
  esac
  shift
done

# Load optional env file for OSINT and delivery credentials.
if [[ -f "$DEFAULT_ENV" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$DEFAULT_ENV"
  set +a
fi

if [[ ! -x "$BRIEF_SCRIPT" ]]; then
  echo "OSINT deliver: missing executable brief.sh at ${BRIEF_SCRIPT}" >&2
  exit 1
fi

brief_json="$(bash "$BRIEF_SCRIPT" $([[ "$FORCE" == "true" ]] && echo "--force"))"
timestamp="$(echo "$brief_json" | jq -r '.briefing_timestamp // .meta.generated_at // "unknown"')"
total_sources="$(echo "$brief_json" | jq -r '.meta.total_sources // 0')"
errors="$(echo "$brief_json" | jq -r '.meta.sources_with_errors // 0')"

top_errors="$(
  echo "$brief_json" | jq -r '
    (.sources // {})
    | to_entries
    | map(select(.value.error or .value.degraded == true))
    | .[:5]
    | map("- " + .key + ": " + (.value.reason // .value.error // "degraded"))
    | if length == 0 then "- none" else .[] end
  ' 2>/dev/null
)"

case "$TEMPLATE" in
  breakingBullet)
    title=":rotating_light: BREAKING BULLET | OSINT Brief"
    ;;
  *)
    title=":satellite: INTEL SIGNAL | OSINT Brief"
    ;;
esac

body="${title}
Time (UTC): ${timestamp}
Coverage: ${total_sources} sources (${errors} degraded/error)

Source health:
${top_errors}
"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "$body"
  exit 0
fi

if [[ -n "${NANOBOT_CHANNELS__SLACK__BOT_TOKEN:-}" && -n "${CHANNEL_ID:-}" ]]; then
  payload="$(jq -nc --arg channel "$CHANNEL_ID" --arg text "$body" '{channel:$channel,text:$text}')"
  code="$(
    curl -sS -o /tmp/osint_slack_resp.json -w "%{http_code}" \
      -X POST "https://slack.com/api/chat.postMessage" \
      -H "Authorization: Bearer ${NANOBOT_CHANNELS__SLACK__BOT_TOKEN}" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data "$payload" || echo "000"
  )"
  if [[ "$code" != "200" ]] || ! jq -e '.ok == true' /tmp/osint_slack_resp.json >/dev/null 2>&1; then
    echo "OSINT deliver: Slack post failed (HTTP ${code})" >&2
    jq -c '.' /tmp/osint_slack_resp.json 2>/dev/null >&2 || true
  fi
  rm -f /tmp/osint_slack_resp.json
fi

if [[ -n "${NTFY_URL:-}" && -n "${NTFY_TOPIC:-}" ]]; then
  ntfy_target="${NTFY_URL%/}/${NTFY_TOPIC}"
  auth_header=()
  if [[ -n "${NTFY_TOKEN:-}" ]]; then
    auth_header=(-H "Authorization: Bearer ${NTFY_TOKEN}")
  fi
  curl -sS --max-time 10 \
    -H "X-Title: OSINT Briefing" \
    -H "X-Markdown: true" \
    "${auth_header[@]}" \
    -d "$body" \
    "$ntfy_target" >/dev/null || true
fi

echo "OSINT deliver: posted using template=${TEMPLATE} channel=${CHANNEL_ID}" >&2

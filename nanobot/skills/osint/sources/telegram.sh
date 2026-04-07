#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../cache"
mkdir -p "$CACHE_DIR"
SOURCE="telegram"
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

# Telegram public channel preview — scrape t.me preview pages
# Using multiple OSINT-relevant channels
channels=("intelslava" "geaborning" "DDGeopolitics")
all_messages="[]"

for channel in "${channels[@]}"; do
  raw=$(curl -sf --max-time 8 \
    -H "User-Agent: Mozilla/5.0" \
    "https://t.me/s/${channel}" 2>/dev/null) || continue

  # Extract message text from the preview HTML
  messages=$(python3 -c "
import sys, json, re, html

content = sys.stdin.read()
msgs = re.findall(r'<div class=\"tgme_widget_message_text[^\"]*\"[^>]*>(.*?)</div>', content, re.DOTALL)
items = []
for m in msgs[-5:]:
    text = re.sub(r'<[^>]+>', '', m)
    text = html.unescape(text).strip()
    if text:
        items.append({'channel': '${channel}', 'text': text[:300]})
print(json.dumps(items))
" <<< "$raw" 2>/dev/null) || messages="[]"

  all_messages=$(jq -nc --argjson a "$all_messages" --argjson b "$messages" '$a + $b')
done

count=$(echo "$all_messages" | jq 'length' 2>/dev/null) || count=0

result=$(jq -nc --arg ts "$ts" --argjson msgs "$all_messages" --argjson count "$count" '{
  source: "telegram",
  fetched_at: $ts,
  count: $count,
  note: "Public channel previews — not authenticated bot access",
  messages: $msgs
}')

echo "$result" | tee "$CACHE_FILE"

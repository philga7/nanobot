#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIEF_SCRIPT="${SCRIPT_DIR}/brief.sh"
DEFAULT_ENV="${HOME}/.wrenvps/osint/.env"

INTEL_DIR="${HOME}/.wrenvps/intel"
INTEL_TOPICS="${INTEL_DIR}/config/topics.json"
INTEL_SOURCES_CFG="${INTEL_DIR}/config/sources.json"

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

# Normalize nested intel RSS/Twitter shapes (feeds.*.items / accounts.*.items) to flat
# arrays so downstream jq matches brief.sh output from both layouts.
# Twitter: unwrap bird-api JSON blobs in .text (cache should ideally parse in
# ~/.wrenvps/intel/sources/fetch-twitter.sh; we harden here too).
if normalized="$(
  echo "$brief_json" | jq -c '
    def strip_first_line_handle(text):
      (text | split("\n")) as $ln
      | if ($ln | length) == 0 then text
        else
          (($ln[0] | gsub("^[[:space:]]*@[A-Za-z0-9_]+[[:space:]]*\\([^)]*\\):[[:space:]]*"; "")) as $f
          | ([$f] + $ln[1:])
          | join("\n"))
        end;
    def unwrap_bird_api(raw):
      (raw | tostring) as $r
      | if ($r | test("^\\s*\\{")) then
          (try (($r | fromjson | .output // .text // "") | tostring) catch $r)
        else $r end;
    def clean_tweet(text):
      strip_first_line_handle(
        (unwrap_bird_api(text)
        | tostring
        | split("\n")
        | map(select(
            (test("^date:|^url:|^PHOTO:|^VIDEO:|^RT @|^>") | not)
            and (test("QT @") | not)
          ))
        | join("\n")
        | gsub("\\s*https?://\\S+"; ""))
      )
      | gsub("^\\s+"; "")
      | gsub("\\s+$"; "");
    .rss = [
      (.rss // [])[]
      | if (type == "object") and has("feeds") and (.feeds | type == "object") then
          (.feeds | to_entries[] | .value as $feed | ($feed.items // [])[] | . + {
            source: ($feed.source // .source // "RSS"),
            tier: ($feed.tier // .tier),
            category: ($feed.category // .category),
            feed: ($feed.feed // .feed),
            published: (.published // .pub_date // .pubDate // .date)
          })
        elif type == "object" then
          .
        else
          empty
        end
    ]
    | .twitter = [
      (.twitter // [])[]
      | if (type == "object") and has("accounts") and (.accounts | type == "object") then
          (.accounts | to_entries[] | .value as $acct | ($acct.items // [])[] | . + {
            handle: ((.handle // $acct.handle // "unknown") | tostring | ltrimstr("@")),
            text: clean_tweet(.text // .content // ""),
            source: ($acct.source // .source),
            tier: ($acct.tier // .tier),
            category: ($acct.category // .category),
            created_at: (.created_at // $acct.created_at // .date)
          })
        elif type == "object" then
          . + {
            handle: ((.handle // .user // .screen_name // "unknown") | tostring | ltrimstr("@")),
            text: clean_tweet(.text // .content // "")
          }
        else
          empty
        end
    ]
  ' 2>/dev/null
)"; then
  brief_json="$normalized"
fi

timestamp="$(echo "$brief_json" | jq -r '.briefing_timestamp // .meta.generated_at // "unknown"')"
total_sources="$(echo "$brief_json" | jq -r '.meta.total_api_sources // .meta.total_sources // 0')"
errors="$(echo "$brief_json" | jq -r '.meta.sources_with_errors // 0')"
rss_items="$(echo "$brief_json" | jq -r '.meta.rss_items // 0')"
twitter_items="$(echo "$brief_json" | jq -r '.meta.twitter_items // 0')"
intel_available="$(echo "$brief_json" | jq -r '.meta.intel_pipeline_available // false')"

# --- Source health summary ---
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

# Load topic weights JSON for inline scoring (empty object if unavailable)
topic_weights_inline="{}"
if [[ -f "$INTEL_TOPICS" ]]; then
  topic_weights_inline="$(jq -c '(.priority_topics // {}) | with_entries(.value |= (. * 10 | floor))' "$INTEL_TOPICS" 2>/dev/null || echo "{}")"
fi

# Load tier maps for inline labeling
tier_mainstream_inline="[]"
tier_alternative_inline="[]"
tier_fringe_inline="[]"
if [[ -f "$INTEL_TOPICS" ]]; then
  tier_mainstream_inline="$(jq -c '[(.source_tier_classification.mainstream // [])[] | ascii_downcase]' "$INTEL_TOPICS" 2>/dev/null || echo "[]")"
  tier_alternative_inline="$(jq -c '[(.source_tier_classification.alternative // [])[] | ascii_downcase]' "$INTEL_TOPICS" 2>/dev/null || echo "[]")"
  tier_fringe_inline="$(jq -c '[(.source_tier_classification.fringe // [])[] | ascii_downcase]' "$INTEL_TOPICS" 2>/dev/null || echo "[]")"
fi

# --- RSS section: ranked by topic weight desc, then recency desc, top 10 ---
rss_section=""
if (( rss_items > 0 )); then
  rss_section="$(
    echo "$brief_json" | jq -r \
      --argjson weights "$topic_weights_inline" \
      --argjson mainstream "$tier_mainstream_inline" \
      --argjson alternative "$tier_alternative_inline" \
      --argjson fringe "$tier_fringe_inline" \
    '
      def score(text):
        ($weights | to_entries
          | map(. as $e | select((text | tostring | ascii_downcase) | test($e.key | ascii_downcase)) | $e.value)
          | add // 0);

      def tier(src):
        if ($mainstream | index(src | ascii_downcase)) != null then " (mainstream)"
        elif ($alternative | index(src | ascii_downcase)) != null then " (alternative)"
        elif ($fringe | index(src | ascii_downcase)) != null then " (fringe)"
        else "" end;

      (.rss // [])
      | map(. + {
          _text: (.title // .headline // .text // ""),
          _src:  (.source // .feed // "RSS"),
          _ts:   (.published // .pubDate // .pub_date // .date // .fetched_at // "")
        })
      | map(select((._text | tostring | test("^\\s*$") | not)))
      | sort_by(. as $row | [-(score($row._text)), ($row._ts | . as $t | -((if $t == "" then 0 else (try ($t | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch 0) end)))])
      | reduce .[] as $row (
          {items: [], used: {}};
          . as $acc
          | ($acc.used[$row._src] // 0) as $n
          | if ($acc.items | length) >= 10 then $acc
            elif $n >= 2 then $acc
            else {
                items: ($acc.items + [$row]),
                used: ($acc.used | .[$row._src] = ($n + 1))
              }
            end
        )
      | .items
      | map(. as $row | "• [" + $row._src + "]" + tier($row._src) + " " + $row._text)
      | .[]
    ' 2>/dev/null || true
  )"
fi

# --- Twitter/X section: ranked by topic weight desc, then recency desc, top 10 ---
twitter_section=""
if (( twitter_items > 0 )); then
  twitter_section="$(
    echo "$brief_json" | jq -r \
      --argjson weights "$topic_weights_inline" \
      --argjson mainstream "$tier_mainstream_inline" \
      --argjson alternative "$tier_alternative_inline" \
      --argjson fringe "$tier_fringe_inline" \
    '
      def strip_first_line_handle(text):
        (text | split("\n")) as $ln
        | if ($ln | length) == 0 then text
          else
            (($ln[0] | gsub("^[[:space:]]*@[A-Za-z0-9_]+[[:space:]]*\\([^)]*\\):[[:space:]]*"; "")) as $f
            | ([$f] + $ln[1:])
            | join("\n"))
          end;
      def unwrap_bird_api(raw):
        (raw | tostring) as $r
        | if ($r | test("^\\s*\\{")) then
            (try (($r | fromjson | .output // .text // "") | tostring) catch $r)
          else $r end;
      def clean_tweet(text):
        strip_first_line_handle(
          (unwrap_bird_api(text)
          | tostring
          | split("\n")
          | map(select(
              (test("^date:|^url:|^PHOTO:|^VIDEO:|^RT @|^>") | not)
              and (test("QT @") | not)
            ))
          | join("\n")
          | gsub("\\s*https?://\\S+"; ""))
        )
        | gsub("^\\s+"; "")
        | gsub("\\s+$"; "");
      def score(text):
        ($weights | to_entries
          | map(. as $e | select((text | tostring | ascii_downcase) | test($e.key | ascii_downcase)) | $e.value)
          | add // 0);

      def tier(handle):
        if ($mainstream | index(handle | ascii_downcase)) != null then " (mainstream)"
        elif ($alternative | index(handle | ascii_downcase)) != null then " (alternative)"
        elif ($fringe | index(handle | ascii_downcase)) != null then " (fringe)"
        else "" end;

      (.twitter // [])
      | map(. + {
          _handle: ((.handle // .user // .screen_name // "unknown") | tostring | ltrimstr("@")),
          _text:   clean_tweet(.text // .content // ""),
          _ts:     (.created_at // .date // .fetched_at // "")
        })
      | map(select((._text | tostring | test("^\\s*$") | not)))
      | sort_by(. as $row | [-(score($row._text)), ($row._ts | . as $t | -((if $t == "" then 0 else (try ($t | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch 0) end)))])
      | .[:10]
      | map(. as $row | "• @" + $row._handle + tier($row._handle) + ": " + $row._text)
      | .[]
    ' 2>/dev/null || true
  )"
fi

# --- Georgia desk subsection ---
georgia_rss=""
if (( rss_items > 0 )); then
  georgia_rss="$(
    echo "$brief_json" | jq -r '
      (.rss // [])
      | map(select(
          ((.title // .headline // .text // "") | tostring | test("^\\s*$") | not)
          and (
            (.title // .headline // .text // "" | ascii_downcase | test("georgia|atlanta|ajc|gpb|gop|kemp|warnock"))
            or (.source // .feed // "" | ascii_downcase | test("ajc|gpb|georgia"))
          )
        ))
      | .[:5]
      | map("• [" + (.source // .feed // "RSS") + "] " + (.title // .headline // .text // "(no title)"))
      | .[]
    ' 2>/dev/null || true
  )"
fi

# --- Topic weight highlights (high-weight matches from RSS/Twitter) ---
# Build a list of high-weight topics (weight >= 1.3) from topics.json
high_weight_topics=""
if [[ -f "$INTEL_TOPICS" ]]; then
  high_weight_topics="$(
    jq -r '
      (.priority_topics // {})
      | to_entries
      | map(select(.value >= 1.3))
      | map(.key | ascii_downcase)
      | join("|")
    ' "$INTEL_TOPICS" 2>/dev/null || true
  )"
fi

# --- Elevated signal items (matching high-weight topics) ---
elevated_items=""
if [[ -n "$high_weight_topics" && ( (( rss_items > 0 )) || (( twitter_items > 0 )) ) ]]; then
  elevated_items="$(
    echo "$brief_json" | jq -r --arg pattern "$high_weight_topics" '
      def matches(t): t | ascii_downcase | test($pattern);
      def nonempty(s): ((s // "") | tostring | test("^\\s*$") | not);
      [
        (.rss // [] | map(select(
          nonempty(.title // .headline // .text // "")
          and (matches(.title // .headline // .text // "")
            or matches(.source // .feed // ""))
        )) | .[:5] | map("• [RSS/" + (.source // .feed // "?") + "] " + (.title // .headline // .text // ""))),
        (.twitter // [] | map(select(
          nonempty(.text // .content // "")
          and matches(.text // .content // "")
        )) | .[:5] | map("• [TW/@" + ((.handle // .user // .screen_name // "?") | ltrimstr("@")) + "] " + (.text // .content // "")))
      ]
      | add // []
      | .[]
    ' 2>/dev/null || true
  )"
fi

# --- Assemble title ---
case "$TEMPLATE" in
  breakingBullet)
    title=":rotating_light: BREAKING BULLET | OSINT Brief"
    ;;
  *)
    title=":satellite: INTEL SIGNAL | OSINT Brief"
    ;;
esac

# --- Compose body ---
body="${title}
Time (UTC): ${timestamp}
Coverage: ${total_sources} API sources | ${rss_items} RSS items | ${twitter_items} tweets (${errors} degraded/error)
"

if [[ -n "$elevated_items" ]]; then
  body+="
ELEVATED — Priority Topics (Iran, Israel, ICE, Tariffs, DOGE, etc.)
${elevated_items}
"
fi

if [[ -n "$rss_section" ]]; then
  body+="
RSS FEEDS (recent headlines)
${rss_section}
"
fi

if [[ -n "$twitter_section" ]]; then
  body+="
TWITTER/X SIGNALS
${twitter_section}
"
fi

if [[ -n "$georgia_rss" ]]; then
  body+="
GEORGIA DESK
${georgia_rss}
"
fi

body+="
Source health (API):
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

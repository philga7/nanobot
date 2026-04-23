#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIEF_SCRIPT="${SCRIPT_DIR}/brief.sh"
LIVE_FEED_SCRIPT="${SCRIPT_DIR}/live-feed.sh"

INTEL_DIR="${HOME}/.wrenvps/intel"
INTEL_TOPICS="${INTEL_DIR}/config/topics.json"
INTEL_SOURCES_CFG="${INTEL_DIR}/config/sources.json"
DEDUP_PY="${SCRIPT_DIR}/sources/dedup.py"
HISTORY_PATH="${INTEL_DIR}/history/news_history.json"
INTEL_SCORING="${INTEL_DIR}/config/scoring.json"
TOPICLESS_FILTER_JQ="${SCRIPT_DIR}/topicless-filter.jq"
BRIEF_MANIFEST="${INTEL_DIR}/history/last_brief_manifest.json"

FORCE=false
DRY_RUN="${DRY_RUN:-false}"
JSON_OUT=""
TEMPLATE="${OSINT_BRIEFING_TEMPLATE:-intelSignal}"
CHANNEL_ID="${OSINT_BRIEFING_SLACK_CHANNEL_ID:-C0AGWCQ1ZDE}"
DESK="${OSINT_DESK:-intel}"
CHANNEL_OVERRIDE=false
LIVE_FEED_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --json)
      JSON_OUT="${2:-}"
      if [[ -z "$JSON_OUT" ]]; then
        echo "deliver.sh: --json requires a filepath" >&2
        exit 1
      fi
      shift 2
      ;;
    --desk)
      DESK="${2:-intel}"
      shift 2
      ;;
    --template)
      TEMPLATE="${2:-$TEMPLATE}"
      shift 2
      ;;
    --channel-id)
      CHANNEL_ID="${2:-$CHANNEL_ID}"
      CHANNEL_OVERRIDE=true
      shift 2
      ;;
    --live-feed)
      LIVE_FEED_MODE=true
      DESK="live-feed"
      shift
      ;;
    *)
      echo "deliver.sh: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -n "$JSON_OUT" && "$DRY_RUN" == "true" ]]; then
  echo "deliver.sh: use either --json or --dry-run, not both" >&2
  exit 1
fi

post_slack_message() {
  local channel="$1"
  local text="$2"
  [[ -n "${NANOBOT_CHANNELS__SLACK__BOT_TOKEN:-}" && -n "$channel" ]] || return 0
  local payload code
  payload="$(jq -nc --arg channel "$channel" --arg text "$text" '{channel:$channel,text:$text}')"
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
}

post_ntfy_message() {
  local title="$1"
  local body="$2"
  [[ -n "${NTFY_URL:-}" && -n "${NTFY_TOPIC:-}" ]] || return 0
  local ntfy_target auth_header=()
  ntfy_target="${NTFY_URL%/}/${NTFY_TOPIC}"
  if [[ -n "${NTFY_TOKEN:-}" ]]; then
    auth_header=(-H "Authorization: Bearer ${NTFY_TOKEN}")
  fi
  curl -sS --max-time 10 \
    -H "X-Title: ${title}" \
    -H "X-Priority: high" \
    "${auth_header[@]}" \
    -d "$body" \
    "$ntfy_target" >/dev/null || true
}

# ISO briefing time (…T…Z) → "19 Apr 2026, 2:00 PM ET" for PDB titles (America/New_York).
iso_to_et_line() {
  local tst="${1:-}"
  if [[ -z "$tst" || "$tst" == "unknown" ]]; then
    printf '%s\n' "$tst"
    return
  fi
  local py=""
  for candidate in \
    "${SCRIPT_DIR}/../../../.venv/bin/python" \
    "${SCRIPT_DIR}/../../../../.venv/bin/python" \
    "$(command -v python3 2>/dev/null)"; do
    if [[ -x "$candidate" ]]; then
      py="$candidate"
      break
    fi
  done
  if [[ -z "$py" ]]; then
    printf '%s\n' "$tst"
    return
  fi
  "$py" - "$tst" <<'PY'
import sys
from datetime import datetime, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None  # type: ignore[misc,assignment]

def main(ts: str) -> str:
    ts = (ts or "").strip()
    if not ts or ts == "unknown":
        return ts
    if ZoneInfo is None:
        return ts
    try:
        if ts.endswith("Z") and "T" in ts:
            dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        else:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
        et = dt.astimezone(ZoneInfo("America/New_York"))
    except Exception:
        return ts
    months = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
    h = et.hour % 12
    if h == 0:
        h = 12
    ampm = "AM" if et.hour < 12 else "PM"
    return f"{et.day} {months[et.month - 1]} {et.year}, {h}:{et.minute:02d} {ampm} ET"


if __name__ == "__main__":
    print(main(sys.argv[1]))
PY
}

# Load optional env files: legacy osint/.env first, then intel/config/.env (canonical overrides)
for _osint_env in "${HOME}/.wrenvps/osint/.env" "${HOME}/.wrenvps/intel/config/.env"; do
  if [[ -f "$_osint_env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$_osint_env"
    set +a
  fi
done

if [[ "$LIVE_FEED_MODE" == "true" ]]; then
  if [[ ! -x "$LIVE_FEED_SCRIPT" ]]; then
    echo "OSINT deliver: missing executable live-feed.sh at ${LIVE_FEED_SCRIPT}" >&2
    exit 1
  fi

  lf_json_path="${JSON_OUT:-/tmp/osint_live_feed.json}"
  bash "$LIVE_FEED_SCRIPT" $([[ "$FORCE" == "true" ]] && echo "--force") $([[ "$DRY_RUN" == "true" ]] && echo "--dry-run") --json "$lf_json_path" >/dev/null
  lf_json="$(jq -c . "$lf_json_path" 2>/dev/null || echo '{}')"

  if [[ -n "$JSON_OUT" ]]; then
    printf '%s\n' "$JSON_OUT"
    exit 0
  fi

  desk_live_channel="$(
    if [[ -f "$INTEL_TOPICS" ]]; then
      jq -r '.desks["live-feed"].channel // empty' "$INTEL_TOPICS" 2>/dev/null || true
    fi
  )"
  live_channel="${OSINT_LIVE_FEED_SLACK_CHANNEL_ID:-${desk_live_channel:-C0ATURFU6MU}}"
  breaking_channel="${OSINT_BREAKING_NEWS_SLACK_CHANNEL_ID:-C0AFVM42G4B}"
  if [[ "$CHANNEL_OVERRIDE" == "true" ]]; then
    live_channel="$CHANNEL_ID"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "$lf_json" | jq .
    exit 0
  fi

  live_item_defs='
    def as_text:
      if . == null then ""
      elif type == "string" then .
      elif type == "object" then (.name // .source // .outlet // .label // "")
      else tostring
      end;
    def source_name($item):
      ($item.source_name // $item.feed_title // $item.feed // $item.source // "Source") as $src
      | ($src | tostring) as $s
      | if ($s | ascii_downcase) == "citizen-free-press" then "CFP"
        elif ($s | ascii_downcase) == "associated-press" then "AP"
        elif ($s | ascii_downcase) == "wall-street-journal" then "WSJ"
        elif ($s | ascii_downcase) == "georgia-public-broadcasting" then "GPB"
        else ($s | gsub("-"; " "))
        end;
    def cfp_relay_source($item):
      ($item.original_source // $item.origin_source // $item.relay_source // null) as $os
      | (
          $item.original_source_name
          // ($os | as_text)
          // (
            ($item.title // "")
            | capture("(?<src>AP|Reuters|Bloomberg|WSJ|CNN|BBC|Fox News|New York Times|NYT|Washington Post|WaPo)"; "i").src?
          )
          // "Original Source"
        );
    def cfp_relay_url($item):
      (
        $item.original_source_url
        // $item.original_url
        // $item.origin_url
        // (
          ($item.original_source // $item.origin_source // $item.relay_source // null)
          | if type == "object" then (.url // .link // "") else "" end
        )
        // ""
      );
    def cfp_has_relay($item):
      (cfp_relay_url($item) | length) > 0;
    def source_parenthetical($item):
      if ($item.type // "") == "twitter" then
        "(@" + (($item.source // $item.handle // "unknown") | tostring | ltrimstr("@")) + ")"
      elif (($item.source // "") | ascii_downcase) == "citizen-free-press" then
        ($item.url // "") as $cfp_url
        | if cfp_has_relay($item) then
            "(<" + $cfp_url + "|CFP>) → (<" + cfp_relay_url($item) + "|" + cfp_relay_source($item) + ">)"
          else
            "(<" + $cfp_url + "|CFP>)"
          end
      else
        "(<" + (($item.url // "") | tostring) + "|" + source_name($item) + ">)"
      end;
    def render_item($item):
      (if (($item.source // "") | ascii_downcase) == "citizen-free-press" and ($item.original_title // "") != "" then
        $item.original_title
      else
        ($item.title // "(no title)")
      end) + " " + source_parenthetical($item);
  '

  message="$(
    echo "$lf_json" | jq -r '
      '"$live_item_defs"'
      | (.items // [])[:20]
      | map(render_item(.))
      | if length == 0 then empty else join("\n\n") end
    ' 2>/dev/null || true
  )"
  if [[ -n "$message" ]]; then
    post_slack_message "$live_channel" "$message"
  fi

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    cp_msg="$(
      echo "$item" | jq -r '
        '"$live_item_defs"'
        | render_item(.)
      ' 2>/dev/null || true
    )"
    [[ -n "$cp_msg" ]] || continue
    post_slack_message "$breaking_channel" "$cp_msg"
  done < <(echo "$lf_json" | jq -c '.cross_post_items[]?')

  ny_hour="$(TZ=America/New_York date +%H)"
  waking_ok=true
  if (( 10#$ny_hour < 7 || 10#$ny_hour >= 23 )); then
    waking_ok=false
  fi
  if [[ "$waking_ok" == "true" ]]; then
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      n_title="$(echo "$item" | jq -r '"LIVE FEED - " + ((.title // "Item") | .[0:70])')"
      n_body="$(echo "$item" | jq -r '(.title // "(no title)") + " [" + (.source // "source") + "]"')"
      post_ntfy_message "$n_title" "$n_body"
    done < <(echo "$lf_json" | jq -c '.ntfy_items[]?')
  fi

  echo "OSINT deliver: desk=live-feed channel=${live_channel}" >&2
  exit 0
fi

desk_json="{}"
desk_api_json="[]"
geo_filter_json="null"
topic_weights_key=""
desk_rss_json="[]"
desk_tw_json="[]"
rss_filter_active="no"
twitter_filter_active="no"

if [[ -f "$INTEL_TOPICS" ]] && command -v jq >/dev/null 2>&1; then
  if jq -e --arg d "$DESK" '.desks != null and (.desks | has($d))' "$INTEL_TOPICS" >/dev/null 2>&1; then
    desk_json="$(jq -c --arg d "$DESK" '.desks[$d]' "$INTEL_TOPICS" 2>/dev/null || echo "{}")"
    desk_api_json="$(echo "$desk_json" | jq -c '(.sources.api // []) | map(ascii_downcase | gsub("-"; "_"))' 2>/dev/null || echo "[]")"
    geo_filter_json="$(echo "$desk_json" | jq -c 'if .geo_filter == null then null else .geo_filter end' 2>/dev/null || echo "null")"
    topic_weights_key="$(echo "$desk_json" | jq -r 'if .topic_weights == null or .topic_weights == "" then "" else .topic_weights end' 2>/dev/null || echo "")"
    desk_rss_json="$(echo "$desk_json" | jq -c '.sources.rss // []' 2>/dev/null || echo "[]")"
    desk_tw_json="$(echo "$desk_json" | jq -c '.sources.twitter // []' 2>/dev/null || echo "[]")"
    rss_filter_active="$(echo "$desk_json" | jq -r 'if (.sources | type) == "object" and (.sources | has("rss")) then "yes" else "no" end' 2>/dev/null || echo "no")"
    twitter_filter_active="$(echo "$desk_json" | jq -r 'if (.sources | type) == "object" and (.sources | has("twitter")) then "yes" else "no" end' 2>/dev/null || echo "no")"
    if [[ "$CHANNEL_OVERRIDE" == "false" ]]; then
      dc="$(echo "$desk_json" | jq -r '.channel // empty' 2>/dev/null || true)"
      if [[ -n "$dc" && "$dc" != "null" ]]; then
        CHANNEL_ID="$dc"
      fi
    fi
  fi
fi

if [[ ! -x "$BRIEF_SCRIPT" ]]; then
  echo "OSINT deliver: missing executable brief.sh at ${BRIEF_SCRIPT}" >&2
  exit 1
fi

brief_json="$(bash "$BRIEF_SCRIPT" $([[ "$FORCE" == "true" ]] && echo "--force") --desk "$DESK")"

# Normalize nested intel RSS/Twitter shapes (feeds.*.items / accounts.*.items) to flat
# arrays so downstream jq matches brief.sh output from both layouts.
# Twitter: unwrap bird-api JSON blobs in .text. Canonical fetch is
# ~/.wrenvps/intel/sources/fetch-twitter.sh; deliver still hardens malformed cache rows here.
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
      (raw | tostring | gsub("^\\s+"; "") | gsub("\\s+$"; "")) as $r
      | if ($r | test("^\\{")) then
          (try (
              ($r | fromjson) as $o
              | (($o.output // $o.text // $o.message // "") | tostring | gsub("^\\s+"; "") | gsub("\\s+$"; "")) as $inner
              | if ($inner | test("^\\{")) then unwrap_bird_api($inner) else $inner end
            ) catch $r)
        elif ($r | test("\\{")) then
          (try (
              ($r | sub("^[^\\{]*"; "") | fromjson) as $o
              | (($o.output // $o.text // $o.message // "") | tostring | gsub("^\\s+"; "") | gsub("\\s+$"; "")) as $inner
              | if ($inner | test("^\\{")) then unwrap_bird_api($inner) else $inner end
            ) catch $r)
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
        | gsub("\\s*https?://\\S+"; "")
        | gsub("\\s*date:\\s*\\S+.*$"; "")
        | gsub("\\s*url:\\s*\\S+.*$"; ""))
      )
      | gsub("^\\s+"; "")
      | gsub("\\s+$"; "");
    def date_line_match(s):
      (s | test("^[A-Za-z]{3}\\s+[A-Za-z]{3}\\s+[0-9]{1,2}\\s+[0-9]{2}:[0-9]{2}:[0-9]{2}\\s+[+-][0-9]{4}\\s+[0-9]{4}$"));
    def date_from_text(s):
      (try (s | capture("date:\\s*(?<d>[A-Za-z]{3}\\s+[A-Za-z]{3}\\s+[0-9]{1,2}\\s+[0-9]{2}:[0-9]{2}:[0-9]{2}\\s+[+-][0-9]{4}\\s+[0-9]{4})").d) catch null);
    def date_to_iso(s):
      if (s // "") == "" then null
      else (try (s | strptime("%a %b %d %H:%M:%S %z %Y") | mktime | strftime("%Y-%m-%dT%H:%M:%SZ")) catch null)
      end;
    def tweet_url_from_text(s):
      (try (s | capture("url:\\s*(?<u>https?://\\S+)").u) catch null);
    def tweet_url_from_line(s):
      (try (s | capture("(?<u>https?://x\\.com/[^/\\s]+/status/[0-9]+)").u) catch null);
    def tweet_id_from_url(s):
      (try (s | capture("/status/(?<id>[0-9]+)").id) catch null);
    def nonempty_str(s):
      ((s // "") | tostring | if length > 0 then . else empty end);
    def rss_canon_url:
      nonempty_str(.url) // nonempty_str(.link) // "";
    .rss = [
      (.rss // [])[]
      | if (type == "object") and has("feeds") and (.feeds | type == "object") then
          (.feeds | to_entries[] | .value as $feed | ($feed.items // [])[] | . + {
            source: ($feed.source // .source // "RSS"),
            tier: ($feed.tier // .tier),
            category: (nonempty_str($feed.category) // nonempty_str(.category) // null),
            feed: ($feed.feed // .feed),
            published: (.published // .pub_date // .pubDate // .date),
            link: (nonempty_str(.link) // nonempty_str($feed.link) // ""),
            url: (. | rss_canon_url)
          })
        elif (type == "object") and has("items") and (.items | type == "array") then
          (. as $row | $row.items[] | . + {
            source: (.source // $row.source // "RSS"),
            tier: (.tier // $row.tier // null),
            category: (nonempty_str(.category) // nonempty_str($row.category) // null),
            feed: (.feed // $row.feed // $row.source // "RSS"),
            published: (.published // .pub_date // .pubDate // .date),
            link: (nonempty_str(.link) // nonempty_str($row.link) // ""),
            url: (. | rss_canon_url)
          })
        elif (type == "object") and (has("title") or has("headline")) then
          . + {
            link: (nonempty_str(.link) // ""),
            url: (. | rss_canon_url)
          }
        else
          empty
        end
    ]
    | .twitter = [
      (.twitter // [])[]
      | if (type == "object") and has("accounts") and (.accounts | type == "object") then
          (.accounts | to_entries[] | .value as $acct | ($acct.items // [])[]
          | (.text // .content // "") as $rawt
          | (unwrap_bird_api($rawt) | tostring) as $raw_unwrapped
          | ($raw_unwrapped | split("\n") | map(gsub("^\\s+"; "") | gsub("\\s+$"; "")) | map(select(length > 0))) as $raw_lines
          | ((date_from_text($raw_unwrapped)) // ($raw_lines | map(select(date_line_match(.))) | .[0] // null)) as $raw_date
          | ((tweet_url_from_text($raw_unwrapped)) // ($raw_lines | map(tweet_url_from_line(.)) | map(select(. != null)) | .[0] // null)) as $extracted
          | (date_to_iso($raw_date)) as $created_at
          | (tweet_id_from_url($extracted)) as $tweet_id
          | . + {
            handle: ((.handle // $acct.handle // "unknown") | tostring | ltrimstr("@")),
            text: clean_tweet($rawt),
            source: ($acct.source // .source),
            tier: ($acct.tier // .tier),
            category: ($acct.category // .category),
            created_at: ($created_at // .created_at // $acct.created_at // .date // null),
            tweet_id: ($tweet_id // .tweet_id // (tweet_id_from_url(.url // "")) // null),
            url: (
              if ($extracted // "") != "" then $extracted
              elif (.url // "") != "" then .url
              elif (.id // null) != null and ((.id | tostring) != "") then "https://x.com/i/web/status/" + (.id | tostring)
              else "" end
            )
          })
        elif type == "object" then
          (.text // .content // "") as $rawt
          | (unwrap_bird_api($rawt) | tostring) as $raw_unwrapped
          | ($raw_unwrapped | split("\n") | map(gsub("^\\s+"; "") | gsub("\\s+$"; "")) | map(select(length > 0))) as $raw_lines
          | ((date_from_text($raw_unwrapped)) // ($raw_lines | map(select(date_line_match(.))) | .[0] // null)) as $raw_date
          | ((tweet_url_from_text($raw_unwrapped)) // ($raw_lines | map(tweet_url_from_line(.)) | map(select(. != null)) | .[0] // null)) as $extracted
          | (date_to_iso($raw_date)) as $created_at
          | (tweet_id_from_url($extracted)) as $tweet_id
          | . + {
            handle: ((.handle // .user // .screen_name // "unknown") | tostring | ltrimstr("@")),
            text: clean_tweet($rawt),
            created_at: ($created_at // .created_at // .date // null),
            tweet_id: ($tweet_id // .tweet_id // (tweet_id_from_url(.url // "")) // null),
            url: (
              if ($extracted // "") != "" then $extracted
              elif (.url // "") != "" then .url
              elif (.id // null) != null and ((.id | tostring) != "") then "https://x.com/i/web/status/" + (.id | tostring)
              else "" end
            )
          }
        else
          empty
        end
    ]
  ' 2>/dev/null
)"; then
  brief_json="$normalized"
fi

# Desk allow-lists from topics: when sources.rss / sources.twitter are present, filter
# brief output here (brief.sh may still load full intel caches). Empty array => no items.
if [[ "$rss_filter_active" == "yes" ]] || [[ "$twitter_filter_active" == "yes" ]]; then
  brief_json="$(
    echo "$brief_json" | jq -c \
      --argjson rss_allow "$desk_rss_json" \
      --argjson tw_allow "$desk_tw_json" \
      --argjson api_allow "$desk_api_json" \
      --arg rss_on "$rss_filter_active" \
      --arg tw_on "$twitter_filter_active" \
      '
      def norm_rss: ascii_downcase | gsub("-"; "");
      def norm_tw: gsub("-"; "") | gsub("_"; "") | ascii_downcase;
      def api_has_gdelt:
        ($api_allow | map(ascii_downcase | gsub("-"; "_")) | index("gdelt") != null);
      (if $rss_on != "yes" then . else
        .rss |= (
          if ($rss_allow | length) == 0 then []
          else map(select(
              (.feed // .source // .id // "" | tostring | norm_rss) as $f
              | (
                  ($rss_allow | map(norm_rss) | index($f) != null)
                  or (api_has_gdelt and $f == "gdelt")
                )
            ))
          end
        )
      end)
      | (if $tw_on != "yes" then . else
        .twitter |= (
          if ($tw_allow | length) == 0 then []
          else map(select(
              (.handle // .user // .screen_name // "" | tostring | ltrimstr("@") | norm_tw) as $h
              | ($tw_allow | map(norm_tw) | index($h) != null)
            ))
          end
        )
      end)
      | .meta = ((.meta // {}) * {rss_items: (.rss | length), twitter_items: (.twitter | length)})
    ' 2>/dev/null || echo "$brief_json"
  )"
fi

# Optional: drop RSS/Twitter rows matching ignored_topic_phrases (plain text, case-insensitive)
ignored_phrases_json="[]"
if [[ -f "$INTEL_TOPICS" ]] && command -v jq >/dev/null 2>&1; then
  ignored_phrases_json="$(
    jq -c '(.ignored_topic_phrases // []) | map(tostring)' "$INTEL_TOPICS" 2>/dev/null || echo '[]'
  )"
fi
if [[ -n "$ignored_phrases_json" && "$ignored_phrases_json" != "[]" ]]; then
  brief_json="$(
    echo "$brief_json" | jq -c --argjson phrases "$ignored_phrases_json" '
      ($phrases | map(ascii_downcase)) as $ph
      | if ($ph | length) == 0 then .
        else
          .rss |= map(
            . as $r
            | (
                (($r.title // "") + " " + ($r.headline // "") + " " + ($r.description // "") + " " + ($r.summary // ""))
                | ascii_downcase
              ) as $b
            | select(any($ph[]?; $b | contains(.)) | not)
          )
          | .twitter |= map(
            . as $t
            | (($t.text // $t.content // "") | ascii_downcase) as $b
            | select(any($ph[]?; $b | contains(.)) | not)
          )
          | .meta = ((.meta // {}) * {rss_items: (.rss | length), twitter_items: (.twitter | length)})
        end
    ' 2>/dev/null || echo "$brief_json"
  )"
fi

# Load topic weights + source tiers (needed before JSON export, topicless filter, PDB)
topic_weights_inline="{}"
if [[ -f "$INTEL_TOPICS" ]] && [[ -n "$topic_weights_key" ]]; then
  topic_weights_inline="$(
    jq -c --arg k "$topic_weights_key" \
      '(.[$k] // {}) | with_entries(.value |= (. * 10 | floor))' "$INTEL_TOPICS" 2>/dev/null || echo "{}"
  )"
fi
tier_mainstream_inline="[]"
tier_alternative_inline="[]"
tier_fringe_inline="[]"
if [[ -f "$INTEL_TOPICS" ]]; then
  tier_mainstream_inline="$(jq -c '[(.source_tier_classification.mainstream // [])[] | ascii_downcase]' "$INTEL_TOPICS" 2>/dev/null || echo "[]")"
  tier_alternative_inline="$(jq -c '[(.source_tier_classification.alternative // [])[] | ascii_downcase]' "$INTEL_TOPICS" 2>/dev/null || echo "[]")"
  tier_fringe_inline="$(jq -c '[(.source_tier_classification.fringe // [])[] | ascii_downcase]' "$INTEL_TOPICS" 2>/dev/null || echo "[]")"
fi

max_items=7
topicless_min="${OSINT_TOPICLESS_MIN_SCORE:-8}"
if [[ -f "$INTEL_SCORING" ]] && command -v jq >/dev/null 2>&1; then
  _mi="$(jq -r --arg t "$TEMPLATE" '.templates[$t].maxItems // empty' "$INTEL_SCORING" 2>/dev/null || true)"
  if [[ -n "${_mi:-}" && "$_mi" != "null" ]]; then
    max_items="$_mi"
  fi
  _tm="$(
    jq -r '.tuning.news.topiclessMinScore // .tuning.topiclessMinScore // empty' "$INTEL_SCORING" 2>/dev/null || true
  )"
  if [[ -n "${_tm:-}" && "$_tm" != "null" ]]; then
    topicless_min="$_tm"
  fi
fi

# "What changed since yesterday": drop rows matching last brief headline hashes
if [[ "$DESK" == "intel" || "$DESK" == "balikatan" ]] && [[ -f "$BRIEF_MANIFEST" ]] && command -v python3 >/dev/null 2>&1; then
  filtered="$(
    printf '%s' "$brief_json" | python3 "$DEDUP_PY" --brief-filter-manifest "$BRIEF_MANIFEST" 2>/dev/null || true
  )"
  if [[ -n "${filtered:-}" ]] && printf '%s' "$filtered" | jq -e . >/dev/null 2>&1; then
    brief_json="$filtered"
  fi
fi

# Non-topic rows must clear composite score floor (see scoring.example.json tuning.news)
if [[ -n "$topic_weights_key" && -f "$INTEL_TOPICS" && -f "$TOPICLESS_FILTER_JQ" ]] && command -v jq >/dev/null 2>&1; then
  topic_weights_raw_json="$(
    jq -c --arg k "$topic_weights_key" '.[$k] // {}' "$INTEL_TOPICS" 2>/dev/null || echo '{}'
  )"
  brief_json="$(
    echo "$brief_json" | jq -c -f "$TOPICLESS_FILTER_JQ" \
      --argjson w "$topic_weights_raw_json" \
      --argjson mainstream "$tier_mainstream_inline" \
      --argjson alternative "$tier_alternative_inline" \
      --argjson fringe "$tier_fringe_inline" \
      --argjson topicless "$topicless_min" \
      2>/dev/null || echo "$brief_json"
  )"
  brief_json="$(
    echo "$brief_json" | jq -c '.meta = ((.meta // {}) * {rss_items: (.rss | length), twitter_items: (.twitter | length)})' 2>/dev/null || echo "$brief_json"
  )"
fi

# Raw JSON for agent-synthesized briefs (no jq report, Slack, or ntfy)
if [[ -n "$JSON_OUT" ]]; then
  out_dir="$(dirname "$JSON_OUT")"
  mkdir -p "$out_dir"
  if ! printf '%s' "$brief_json" | jq -c . >"$JSON_OUT"; then
    echo "deliver.sh: failed to write valid JSON to ${JSON_OUT}" >&2
    exit 1
  fi
  printf '%s\n' "$JSON_OUT"
  exit 0
fi

timestamp="$(echo "$brief_json" | jq -r '.briefing_timestamp // .meta.generated_at // "unknown"')"
total_sources="$(echo "$brief_json" | jq -r '.meta.total_api_sources // .meta.total_sources // 0')"
rss_items="$(echo "$brief_json" | jq -r '(.rss // []) | length')"
twitter_items="$(echo "$brief_json" | jq -r '(.twitter // []) | length')"
intel_available="$(echo "$brief_json" | jq -r '.meta.intel_pipeline_available // false')"
errors="$(
  echo "$brief_json" | jq -r --argjson apis "$desk_api_json" '
    [.sources // {} | to_entries[]
      | select(
          (.key | ascii_downcase | gsub("-"; "_")) as $kn
          | (if ($apis | length) == 0 then true else ($apis | index($kn) != null) end)
        )
      | select(.value.error or .value.degraded == true)
    ] | length
  ' 2>/dev/null || echo "0"
)"

# --- Source health: only APIs on this desk (when desk lists sources.api) ---
top_errors="$(
  echo "$brief_json" | jq -r --argjson apis "$desk_api_json" '
    def in_desk($k):
      ($k | ascii_downcase | gsub("-"; "_")) as $kn
      | if ($apis | length) == 0 then true else ($apis | index($kn) != null) end;
    (.sources // {})
    | to_entries
    | map(select(.value.error or .value.degraded == true))
    | map(select(in_desk(.key)))
    | .[:5]
    | map("- " + .key + ": " + (.value.reason // .value.error // "degraded"))
    | if length == 0 then "- none" else .[] end
  ' 2>/dev/null
)"

# --- KEY INDICATORS + aggregated Data: line ---
KEY_INDICATORS_JQ="${SCRIPT_DIR}/key-indicators.jq"
pdb_mode_arg="0"
if [[ "$DESK" == "intel" || "$DESK" == "balikatan" ]]; then
  pdb_mode_arg="1"
fi
api_section=""
data_status=""
pdb_key_block=""
pdb_promoted_sections_json="[]"
pdb_data_notes=""
ki="{}"
if [[ -f "$KEY_INDICATORS_JQ" ]]; then
  ki="$(
    echo "$brief_json" | jq -c -f "$KEY_INDICATORS_JQ" \
      --argjson desk_api "$desk_api_json" \
      --argjson geo_filter "$geo_filter_json" \
      --arg pdb_mode "$pdb_mode_arg" \
      2>/dev/null || echo '{"indicator_lines":[],"data_status":null,"pdb_key_indicator_lines":[],"pdb_promoted_sections":[],"pdb_data_notes":null}'
  )"
  if [[ "$pdb_mode_arg" == "1" ]]; then
    pdb_key_block="$(echo "$ki" | jq -r '(.pdb_key_indicator_lines // []) | join("\n")' 2>/dev/null || true)"
    pdb_promoted_sections_json="$(echo "$ki" | jq -c '.pdb_promoted_sections // []' 2>/dev/null || echo '[]')"
    pdb_data_notes="$(echo "$ki" | jq -r '.pdb_data_notes // empty' 2>/dev/null || true)"
  else
    api_section="$(echo "$ki" | jq -r '.indicator_lines[]?' 2>/dev/null || true)"
    data_status="$(echo "$ki" | jq -r '.data_status // empty' 2>/dev/null || true)"
  fi
fi

# --- PRECIOUS METALS (investing desk) ---
precious_section=""
if [[ "$DESK" == "investing" ]]; then
  threshold="$(echo "$desk_json" | jq -c '.precious_metals.alert_threshold_pct // 5.0' 2>/dev/null || echo "5.0")"
  precious_section="$(
    echo "$brief_json" | jq -r --argjson th "$threshold" '
      (.sources.gold_api // null) as $g
      | if $g == null or ($g.assets // null) == null then empty
        else
          ($g.assets // {}) as $a
          | def fmt($sym; $label):
              ($a[$sym] // null) as $x
              | if $x == null or ($x.price == null) then empty
                else
                  ($x.change_pct_day // 0) as $pct
                  | (if $pct < 0 then -$pct else $pct end) as $ab
                  | (if ($ab >= ($th | tonumber)) then " ALERT" else "" end) as $al
                  | "\($label) $\($x.price | tostring | sub("\\.[0-9]{3,}$"; "")) ("
                    + (if $pct >= 0 then "+" else "" end)
                    + ($pct | tostring | .[0:6]) + "%)\($al)"
                end;
          [
            (fmt("XAU"; "GOLD")),
            (fmt("XAG"; "SILVER"))
          ] | map(select(length > 0)) | join(" | ")
        end
    ' 2>/dev/null || true
  )"
fi

# --- FORECAST MODELS (weather desk): model spread + per-model day-0 detail ---
forecast_section=""
if [[ "$DESK" == "weather" ]]; then
  spread_lines="$(
    echo "$brief_json" | jq -r '
      def labs: ["ECMWF", "GFS", "NAM"];
      def num(v):
        if v == null then null
        elif (v | type) == "number" then v
        else (v | tonumber? // null) end;
      def highs_at($c; $i):
        [
          labs[] as $L
          | ($c.models[$L].daily.temperature_2m_max[$i] // null) as $v
          | if $v == null then empty
            else num($v) as $h
            | if $h == null then empty else {m: $L, h: $h} end
            end
        ];
      def spread_for_day($c; $i):
        ($c.name // "?") as $nm
        | highs_at($c; $i) as $hs
        | (
            ($c.models.ECMWF.daily.time // $c.models.GFS.daily.time // $c.models.NAM.daily.time // [])
          ) as $times
        | ($times[$i] // "") as $day
        | if ($hs | length) < 2 then empty
          else
            ($hs | map(.h) | max) as $x
            | ($hs | map(.h) | min) as $n
            | ($x - $n) as $sp
            | ($hs | map(select(.h == $x)) | map(.m) | unique | join("/")) as $warm
            | ($hs | map(select(.h == $n)) | map(.m) | unique | join("/")) as $cool
            | (if $sp >= 5 then " — disagree (>=5°F spread)" else "" end) as $flag
            | "• \($nm) | \($day) — ΔHigh \($sp | tostring | .[0:5])°F (\($warm) \($x)°F vs \($cool) \($n)°F)\($flag)"
          end;
      (.sources.forecast_models.cities // [])[] as $c
      | (
          ($c.models.ECMWF.daily.time // $c.models.GFS.daily.time // $c.models.NAM.daily.time // [])
          | length
        ) as $nlen
      | range(0; ([3, $nlen] | min)) as $i
      | spread_for_day($c; $i)
    ' 2>/dev/null || true
  )"
  detail_lines="$(
    echo "$brief_json" | jq -r '
      def labs: ["ECMWF", "GFS", "NAM"];
      def num(v):
        if v == null then null
        elif (v | type) == "number" then v
        else (v | tonumber? // null) end;
      (.sources.forecast_models.cities // [])[] as $c
      | ($c.name // "?") as $nm
      | labs[] as $lab
      | ($c.models[$lab].daily // {}) as $d
      | ($d.time[0] // "") as $t0
      | ((num($d.temperature_2m_max[0]) // "?") | tostring) as $hi
      | ((num($d.temperature_2m_min[0]) // "?") | tostring) as $lo
      | ($d.precipitation_probability_mean[0] // "?") as $pr
      | ($d.wind_speed_10m_max[0] // "?") as $ws
      | "• \($nm) [\($lab)] \($t0) Hi \($hi)°F Lo \($lo)°F | rain \($pr)% | wind \($ws) mph"
    ' 2>/dev/null || true
  )"
  if [[ -n "${spread_lines//[$'\t\r\n ']}" ]]; then
    forecast_section="Model spread (next 3 days, max high temp across models, °F):
${spread_lines}

By model (first forecast day, °F / mph):
${detail_lines}"
  else
    forecast_section="${detail_lines}"
  fi
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
      | map(. as $row | "• [" + $row._src + "]" + tier($row._src) + " " + ($row._text | tostring | if length > 150 then .[0:150] + "..." else . end) + (if ($row.url // "" | test("^https?://")) then "\n  → " + $row.url else "" end))
      | .[]
    ' 2>/dev/null || true
  )"
fi

# --- Twitter/X section ---
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
        (raw | tostring | gsub("^\\s+"; "") | gsub("\\s+$"; "")) as $r
        | if ($r | test("^\\{")) then
            (try (
                ($r | fromjson) as $o
                | (($o.output // $o.text // $o.message // "") | tostring | gsub("^\\s+"; "") | gsub("\\s+$"; "")) as $inner
                | if ($inner | test("^\\{")) then unwrap_bird_api($inner) else $inner end
              ) catch $r)
          elif ($r | test("\\{")) then
            (try (
                ($r | sub("^[^\\{]*"; "") | fromjson) as $o
                | (($o.output // $o.text // $o.message // "") | tostring | gsub("^\\s+"; "") | gsub("\\s+$"; "")) as $inner
                | if ($inner | test("^\\{")) then unwrap_bird_api($inner) else $inner end
              ) catch $r)
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
          | gsub("\\s*https?://\\S+"; "")
          | gsub("\\s*date:\\s*\\S+.*$"; "")
          | gsub("\\s*url:\\s*\\S+.*$"; ""))
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
      | map(. as $row | "• @" + $row._handle + tier($row._handle) + ": " + ($row._text | tostring | if length > 200 then .[0:200] + "..." else . end) + (if ($row.url // "" | test("^https?://")) then "\n  → " + $row.url else "" end))
      | .[]
    ' 2>/dev/null || true
  )"
fi

# --- Georgia desk subsection (intel desk only) ---
georgia_rss=""
if [[ "$DESK" == "intel" ]] && (( rss_items > 0 )); then
  georgia_rss="$(
    echo "$brief_json" | jq -r '
      (.rss // [])
      | map(. + {_text: (.title // .headline // .text // "")})
      | map(select(
          (._text | tostring | test("^\\s*$") | not)
          and (
            ((.category // "") | test("georgia"; "i"))
            or ((.source // "") | test("capitol-beat|ga-pundit|georgia-recorder|georgia-recorder-local|gpb-georgia|ajc|gpb|georgia"; "i"))
            or ((.feed // "") | test("capitol-beat|ga-pundit|georgia-recorder|georgia-recorder-local|gpb-georgia|ajc|gpb|georgia"; "i"))
            or ((._text // "") | test("georgia|atlanta|kemp|warnock|ossoff|fani willis|ajc|gpb|gop"; "i"))
          )
        ))
      | .[:5]
      | map("• [" + (.source // .feed // "RSS") + "] " + (.title // .headline // .text // "(no title)") + (if ((.url // "") | test("^https?://")) then "\n  → " + .url else "" end))
      | .[]
    ' 2>/dev/null || true
  )"
fi

# --- Topic weight highlights (intel / weighted desks only) ---
high_weight_topics=""
if [[ -n "$topic_weights_key" ]] && [[ -f "$INTEL_TOPICS" ]]; then
  high_weight_topics="$(
    jq -r --arg k "$topic_weights_key" '
      (.[$k] // {})
      | to_entries
      | map(select(.value >= 1.3))
      | map(.key | ascii_downcase)
      | join("|")
    ' "$INTEL_TOPICS" 2>/dev/null || true
  )"
fi

# --- Elevated signal items ---
elevated_items=""
if [[ -n "$topic_weights_key" && -n "$high_weight_topics" && ( (( rss_items > 0 )) || (( twitter_items > 0 )) ) ]]; then
  elevated_items="$(
    echo "$brief_json" | jq -r --arg pattern "$high_weight_topics" '
      def matches(t): t | ascii_downcase | test($pattern);
      def nonempty(s): ((s // "") | tostring | test("^\\s*$") | not);
      def trunc_rss(s): ((s // "") | tostring | if length > 150 then .[0:150] + "..." else . end);
      def trunc_tw(s): ((s // "") | tostring | if length > 200 then .[0:200] + "..." else . end);
      [
        (.rss // [] | map(select(
          nonempty(.title // .headline // .text // "")
          and (matches(.title // .headline // .text // "")
            or matches(.source // .feed // ""))
        )) | .[:5] | map("• [RSS/" + (.source // .feed // "?") + "] " + trunc_rss(.title // .headline // .text // "") + (if ((.url // "") | test("^https?://")) then "\n  → " + .url else "" end))),
        (.twitter // [] | map(select(
          nonempty(.text // .content // "")
          and matches(.text // .content // "")
        )) | .[:5] | map("• [TW/@" + ((.handle // .user // .screen_name // "?") | ltrimstr("@")) + "] " + trunc_tw(.text // .content // "") + (if ((.url // "") | test("^https?://")) then "\n  → " + .url else "" end)))
      ]
      | add // []
      | .[]
    ' 2>/dev/null || true
  )"
fi

# --- Title / template ---
case "$TEMPLATE" in
  breakingBullet)
    case "$DESK" in
      intel)
        title="**INTEL SIGNAL — $(iso_to_et_line "$timestamp")**"
        ;;
      work)
        title="WORK INTELLIGENCE — $(iso_to_et_line "$timestamp")"
        ;;
      balikatan)
        title="**BALIKATAN BRIEF — $(iso_to_et_line "$timestamp")**"
        ;;
      *)
        title=":rotating_light: BREAKING BULLET | OSINT Brief"
        ;;
    esac
    ;;
  *)
    case "$DESK" in
      investing)
        title=":chart_with_upwards_trend: INVESTING DESK | OSINT Brief"
        ;;
      weather)
        et_time="$(date -d "$timestamp" +"%-d %b %Y, %-I:%M %p ET" 2>/dev/null || echo "$timestamp")"
        title="WEATHER BRIEF — ${et_time}"
        ;;
      intel)
        title="**INTEL SIGNAL — $(iso_to_et_line "$timestamp")**"
        ;;
      balikatan)
        title="**BALIKATAN BRIEF — $(iso_to_et_line "$timestamp")**"
        ;;
      *)
        title=":satellite: INTEL SIGNAL | OSINT Brief"
        ;;
    esac
    ;;
esac

# --- Compose body ---
if [[ "$DESK" == "weather" ]]; then
  body="${title}

**ALERTS:** [Agent: write alert summary — local counties first (Jackson, Lumpkin, Bulloch), then national systems that could track toward SE. If none, say \"None active for our area. No watches, warnings, or advisories for Jackson, Lumpkin, or Bulloch counties. Clear sailing.\"]

**Current Conditions**
[Agent: one-line per locality — City: temp° condition]

**Jefferson, GA**
[Agent: current conditions line + 2-3 sentence narrative forecast]

**Dahlonega, GA**
[Agent: current conditions line + 2-3 sentence narrative forecast]

**Statesboro, GA**
[Agent: current conditions line + 2-3 sentence narrative forecast]

**Model Agreement:** [Agent: write narrative assessment of model agreement level — Very Strong / Strong / Moderate / Weak. Summarize what models agree on and where they diverge. Sub-bullets for Temps, Wind, other factors.]
•   Temps: [narrative]
•   Wind: [narrative]

**Key Notes:**
•   [Agent: 3-5 bullet points on notable trends, changes, things to watch]
"
elif [[ "$DESK" == "work" ]]; then
  body="${title}

**Bottom Line:** [Agent: 1-2 sentence summary of the biggest federal contracting developments]

**Competitor Moves**
[Agent: narrative summary of competitor activity - new awards, press releases, hiring, strategy shifts]
→ [Source: Headline]

**Vehicle & Program Updates**
[Agent: narrative summary of IDIQ/program developments]
→ [Source: Headline]

**DoD/MDA Policy**
[Agent: narrative summary of policy/budget changes]
→ [Source: Headline]

**Industry Trends**
[Agent: narrative summary of broader defense contracting trends]
→ [Source: Headline]

**Contract Actions (recent)**
[Agent: 2-3 notable contract awards from fed-contracts data in this JSON. Not a full dump - just highlights.]
• [Recipient] - $[Amount] [Description] ([Date])

**Elevated Watch:** [Agent: topics to monitor - upcoming RFPs, expiring contracts, budget markups]
"
elif [[ "$DESK" == "intel" || "$DESK" == "balikatan" ]]; then
  source_health_line="$(
    echo "$brief_json" | jq -r --argjson apis "$desk_api_json" '
      def in_desk($k):
        ($k | ascii_downcase | gsub("-"; "_")) as $kn
        | if ($apis | length) == 0 then true else ($apis | index($kn) != null) end;
      (.sources // {})
      | [
          to_entries[]?
          | select(in_desk(.key))
          | select(.value.error or .value.degraded == true)
          | (.key | gsub("_"; " ") | ascii_upcase)
        ]
      | if length == 0 then "All sources operational"
        else "\(length) degraded (\(join(", ")))"
        end
    ' 2>/dev/null || echo "All sources operational"
  )"
  elevated_watch_topics=""
  if [[ -n "$topic_weights_key" ]] && [[ -f "$INTEL_TOPICS" ]]; then
    elevated_watch_topics="$(
      jq -r --arg k "$topic_weights_key" '
        (.[$k] // {})
        | to_entries
        | map(select(.value >= 1.3))
        | map(.key | ascii_downcase)
        | join(" · ")
      ' "$INTEL_TOPICS" 2>/dev/null || true
    )"
  fi
  _cap_items="$(printf '%d' "${max_items:-7}" 2>/dev/null || echo 7)"
  topic_bundle="$(
    echo "$brief_json" | jq -c -f "${SCRIPT_DIR}/intel-pdb-topics.jq" \
      --argjson weights "${topic_weights_inline:-{}}" \
      --argjson promoted_sections "${pdb_promoted_sections_json:-[]}" \
      --argjson max_total "${_cap_items}" \
      --arg desk "$DESK" 2>/dev/null || echo '{"topic_sections":"","georgia_section":"","also_noted":"","manifest_titles":[]}'
  )"
  topic_sections_text="$(echo "$topic_bundle" | jq -r '.topic_sections // ""' 2>/dev/null || true)"
  georgia_section_text="$(echo "$topic_bundle" | jq -r '.georgia_section // ""' 2>/dev/null || true)"
  also_noted_text="$(echo "$topic_bundle" | jq -r '.also_noted // ""' 2>/dev/null || true)"

  body="${title}
"
  body+="**Bottom Line:** [Agent: write 1-2 sentence summary of top stories]
"
  if [[ -n "${pdb_key_block//[$'\t\r\n ']}" ]]; then
    body+="
**Key Indicators**
${pdb_key_block}
"
  fi
  if [[ -n "${topic_sections_text//[$'\t\r\n ']}" ]]; then
    body+="
${topic_sections_text}
"
  fi
  if [[ "$DESK" == "intel" ]]; then
    body+="
**Markets**
[Agent: one compact line from JSON (yfinance / treasury / gold-api / EIA if present). Example: S&P 5,XXX (+X.X%) | 10Y X.XX% | Gold \$X,XXX | Oil \$XX — use → links where helpful]
"
  fi
  if [[ -n "${also_noted_text//[$'\t\r\n ']}" ]]; then
    body+="
**Also noted**
${also_noted_text}
"
  fi
  _mf_hits="$(echo "$brief_json" | jq -r '.meta.brief_manifest_hits // 0' 2>/dev/null || echo 0)"
  if [[ "$DESK" == "intel" && "${_mf_hits:-0}" =~ ^[0-9]+$ ]] && (( _mf_hits > 0 )); then
    body+="
**Ongoing**
[Agent: for priority topics with no new headline since the last brief, one line each: → Topic: no new developments]
"
  fi
  if [[ "$DESK" == "intel" && -n "${georgia_section_text//[$'\t\r\n ']}" ]]; then
    body+="
**Georgia**
${georgia_section_text}
"
  fi
  if [[ -n "${elevated_watch_topics//[$'\t\r\n ']}" ]]; then
    body+="
**Elevated Watch:** ${elevated_watch_topics}
"
  fi
  body+="
**Analyst Note:** [Agent: write assessment of big stories, what to watch next]
"
  body+="
**Source Health:** ${source_health_line}
"
  if [[ -n "${pdb_data_notes//[$'\t\r\n ']}" ]]; then
    body+="
**Data Notes:** ${pdb_data_notes}
"
  fi
else
  body="${title}
Time (UTC): ${timestamp}
Desk: ${DESK} — Coverage: ${total_sources} API sources | ${rss_items} RSS items | ${twitter_items} tweets (${errors} degraded/error)
"

  if [[ -n "$api_section" ]]; then
    body+="
KEY INDICATORS
${api_section}
"
  fi

  if [[ "$DESK" == "investing" && -n "$precious_section" ]]; then
    body+="
PRECIOUS METALS
• ${precious_section}
"
  fi

  if [[ "$DESK" != "weather" && -n "$forecast_section" ]]; then
    body+="
FORECAST MODELS (ECMWF / GFS / NAM, °F / mph)
${forecast_section}
"
  fi

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

  if [[ -n "$data_status" ]]; then
    body+="
${data_status}
"
  fi
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "$body"
  exit 0
fi

post_slack_message "$CHANNEL_ID" "$body"
post_ntfy_message "OSINT Briefing" "$body"

if [[ "$DESK" == "intel" || "$DESK" == "balikatan" ]] && [[ -n "${topic_bundle:-}" ]] && command -v python3 >/dev/null 2>&1; then
  echo "$topic_bundle" | jq -c '{titles:(.manifest_titles // [])}' 2>/dev/null \
    | python3 "$DEDUP_PY" --brief-save-manifest "$BRIEF_MANIFEST" >/dev/null 2>&1 || true
fi

# --- Global dedup: register all posted items in news_history.json ---
if [[ -x "$DEDUP_PY" ]] && [[ "$DRY_RUN" != "true" ]] && [[ "$DESK" != "live-feed" ]]; then
  if [[ -n "${brief_json:-}" ]]; then
    echo "$brief_json" | jq -c '.rss[]? // empty' 2>/dev/null | while IFS= read -r row; do
      key="$(echo "$row" | jq -r '(.guid // .id // .url // .link // "") | tostring' 2>/dev/null)"
      [[ -n "$key" && "$key" != "" && "$key" != "null" ]] || continue
      payload="$(echo "$row" | jq -c --arg k "$key" --arg desk "$DESK" --arg ch "#${DESK}" '{key:$k,first_seen:(.pub_date//.pubDate//null),source:(.feed_title//.source//null),source_type:"rss",title:.title,desks:[$desk],channels:[$ch]}')"
      printf '%s\n' "$payload" | python3 "$DEDUP_PY" --history "$HISTORY_PATH" --add - >/dev/null 2>&1 || true
    done
    echo "$brief_json" | jq -c '.twitter[]? // empty' 2>/dev/null | while IFS= read -r row; do
      key="$(echo "$row" | jq -r '(.tweet_id // .id // .url // "") | tostring' 2>/dev/null)"
      [[ -n "$key" && "$key" != "" && "$key" != "null" ]] || continue
      payload="$(echo "$row" | jq -c --arg k "$key" --arg desk "$DESK" --arg ch "#${DESK}" '{key:$k,source:(.handle//.screen_name//.account//null),source_type:"twitter",title:(.text//.content//.full_text//null),desks:[$desk],channels:[$ch]}')"
      printf '%s\n' "$payload" | python3 "$DEDUP_PY" --history "$HISTORY_PATH" --add - >/dev/null 2>&1 || true
    done
    python3 "$DEDUP_PY" --history "$HISTORY_PATH" --prune 7 >/dev/null 2>&1 || true
  fi
fi

echo "OSINT deliver: desk=${DESK} template=${TEMPLATE} channel=${CHANNEL_ID}" >&2

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIEF_SCRIPT="${SCRIPT_DIR}/brief.sh"
LIVE_FEED_SCRIPT="${SCRIPT_DIR}/live-feed.sh"

INTEL_DIR="${HOME}/.wrenvps/intel"
INTEL_TOPICS="${INTEL_DIR}/config/topics.json"
INTEL_SOURCES_CFG="${INTEL_DIR}/config/sources.json"

FORCE=false
DRY_RUN=false
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

  live_channel="${OSINT_LIVE_FEED_SLACK_CHANNEL_ID:-C0ALXXXXXXX}"
  breaking_channel="${OSINT_BREAKING_NEWS_SLACK_CHANNEL_ID:-C0AFVM42G4B}"
  if [[ "$CHANNEL_OVERRIDE" == "true" ]]; then
    live_channel="$CHANNEL_ID"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "$lf_json" | jq .
    exit 0
  fi

  message="$(
    echo "$lf_json" | jq -r '
      . as $root
      | ($root.swept_at // "" | sub("T"; " ") | sub("Z$"; " UTC")) as $ts
      | "🔴 LIVE FEED | " + $ts + "\n\n"
        + ((.items // [])[:20]
          | map(.urgency + " | " + (.title // "(no title)"))
          | join("\n"))
        + "\n\nSources: CFP (" + (((.items // []) | map(select(.source == "citizen-free-press")) | length) | tostring)
        + ") | Twitter (" + (((.items // []) | map(select(.type == "twitter")) | length) | tostring) + ")"
    '
  )"
  if [[ -n "$message" ]]; then
    post_slack_message "$live_channel" "$message"
  fi

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    cp_msg="$(echo "$item" | jq -r '
      "⚡ CROSS-POST from #live-feed | Score " + ((.score // 0 | tostring)) + "\n\n"
      + (.title // "(no title)") + "\n"
      + (.url // "") + "\n\n"
      + "Topic tags: " + ((.topic_tags // []) | join(", "))
      + " | Source: " + (.source // "") + " (" + (.source_tier // "unknown") + ")"
    ')"
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
          | (($rawt | tostring | [scan("https?://[^\\s\"<>]+")] | .[0] // "")) as $extracted
          | . + {
            handle: ((.handle // $acct.handle // "unknown") | tostring | ltrimstr("@")),
            text: clean_tweet($rawt),
            source: ($acct.source // .source),
            tier: ($acct.tier // .tier),
            category: ($acct.category // .category),
            created_at: (.created_at // $acct.created_at // .date),
            url: (
              if $extracted != "" then $extracted
              elif (.url // "") != "" then .url
              elif (.id // null) != null and ((.id | tostring) != "") then "https://x.com/i/web/status/" + (.id | tostring)
              else "" end
            )
          })
        elif type == "object" then
          (.text // .content // "") as $rawt
          | (($rawt | tostring | [scan("https?://[^\\s\"<>]+")] | .[0] // "")) as $extracted
          | . + {
            handle: ((.handle // .user // .screen_name // "unknown") | tostring | ltrimstr("@")),
            text: clean_tweet($rawt),
            url: (
              if $extracted != "" then $extracted
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

# Load topic weights JSON for inline scoring (empty object if desk skips weighting)
topic_weights_inline="{}"
if [[ -f "$INTEL_TOPICS" ]] && [[ -n "$topic_weights_key" ]]; then
  topic_weights_inline="$(
    jq -c --arg k "$topic_weights_key" \
      '(.[$k] // {}) | with_entries(.value |= (. * 10 | floor))' "$INTEL_TOPICS" 2>/dev/null || echo "{}"
  )"
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

# --- KEY INDICATORS + aggregated Data: line ---
KEY_INDICATORS_JQ="${SCRIPT_DIR}/key-indicators.jq"
api_section=""
data_status=""
if [[ -f "$KEY_INDICATORS_JQ" ]]; then
  ki="$(
    echo "$brief_json" | jq -c -f "$KEY_INDICATORS_JQ" \
      --argjson desk_api "$desk_api_json" \
      --argjson geo_filter "$geo_filter_json" 2>/dev/null || echo '{"indicator_lines":[],"data_status":null}'
  )"
  api_section="$(echo "$ki" | jq -r '.indicator_lines[]?' 2>/dev/null || true)"
  data_status="$(echo "$ki" | jq -r '.data_status // empty' 2>/dev/null || true)"
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
    title=":rotating_light: BREAKING BULLET | OSINT Brief"
    ;;
  *)
    case "$DESK" in
      investing)
        title=":chart_with_upwards_trend: INVESTING DESK | OSINT Brief"
        ;;
      weather)
        title=":cloud: WEATHER DESK | OSINT Brief"
        ;;
      *)
        title=":satellite: INTEL SIGNAL | OSINT Brief"
        ;;
    esac
    ;;
esac

# --- Compose body ---
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

if [[ "$DESK" == "weather" && -n "$forecast_section" ]]; then
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

if [[ "$DRY_RUN" == "true" ]]; then
  echo "$body"
  exit 0
fi

post_slack_message "$CHANNEL_ID" "$body"
post_ntfy_message "OSINT Briefing" "$body"

echo "OSINT deliver: desk=${DESK} template=${TEMPLATE} channel=${CHANNEL_ID}" >&2

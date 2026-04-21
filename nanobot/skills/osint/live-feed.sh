#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEDUP_PY="${SCRIPT_DIR}/sources/dedup.py"

INTEL_DIR="${HOME}/.wrenvps/intel"
INTEL_TOPICS="${INTEL_DIR}/config/topics.json"
INTEL_SOURCES_CFG="${INTEL_DIR}/config/sources.json"
INTEL_FETCH_RSS="${INTEL_DIR}/sources/fetch-rss.sh"
INTEL_FETCH_TWITTER="${INTEL_DIR}/sources/fetch-twitter.sh"
INTEL_CACHE_RSS="${INTEL_DIR}/cache/rss"
INTEL_CACHE_TWITTER="${INTEL_DIR}/cache/twitter"
HISTORY_PATH="${INTEL_DIR}/history/news_history.json"
SWEEP_STATE="${INTEL_DIR}/live-feed/last_sweep.json"

DESK="live-feed"
FORCE=false
DRY_RUN=false
JSON_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --json)
      JSON_OUT="${2:-}"
      [[ -n "$JSON_OUT" ]] || { echo "live-feed.sh: --json requires a filepath" >&2; exit 1; }
      shift 2
      ;;
    --desk)
      DESK="${2:-live-feed}"
      shift 2
      ;;
    *)
      echo "live-feed.sh: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

[[ "$DESK" == "live-feed" ]] || { echo "live-feed.sh: only --desk live-feed is supported" >&2; exit 1; }

if [[ ! -f "$INTEL_TOPICS" ]]; then
  echo "live-feed.sh: missing topics config at ${INTEL_TOPICS}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "live-feed.sh: jq is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "live-feed.sh: python3 is required" >&2
  exit 1
fi

desk_json="$(jq -c '.desks["live-feed"] // {}' "$INTEL_TOPICS" 2>/dev/null || echo '{}')"
[[ "$desk_json" != "{}" ]] || { echo "live-feed.sh: desks.live-feed not found in topics.json" >&2; exit 1; }

channel_id="$(echo "$desk_json" | jq -r '.channel // empty')"
rss_allow="$(echo "$desk_json" | jq -c '.sources.rss // []')"
tw_allow="$(echo "$desk_json" | jq -c '.sources.twitter // []')"
weights_key="$(echo "$desk_json" | jq -r '.topic_weights // "priority_topics"')"
cfg="$(echo "$desk_json" | jq -c '.live_feed_config // {}')"
cfp_item_limit="$(echo "$cfg" | jq -r '.cfp_item_limit // 30')"
twitter_lookback_min="$(echo "$cfg" | jq -r '.twitter_lookback_min // 35')"
ntfy_weight_threshold="$(echo "$cfg" | jq -r '.ntfy_weight_threshold // 1.3')"
cross_post_breaking="$(echo "$cfg" | jq -r '.cross_post_breaking // true')"
breaking_score_threshold="$(echo "$cfg" | jq -r '.breaking_score_threshold // 6')"

major_keywords_json="$(jq -c '.major_event_keywords // []' "$INTEL_TOPICS" 2>/dev/null || echo '[]')"
topic_weights_json="$(jq -c --arg k "$weights_key" '
  (.[$k] // []) |
  if type == "array" then
    [.[] | .keywords[] as $kw | {($kw): .weight}] | add // {}
  else
    with_entries(.value |= .weight // .)
  end
' "$INTEL_TOPICS" 2>/dev/null || echo '{}')"

if [[ -x "$INTEL_FETCH_RSS" ]]; then
  OSINT_RSS_ITEM_LIMIT_OVERRIDE="citizen-free-press:${cfp_item_limit}" \
    bash "$INTEL_FETCH_RSS" $([[ "$FORCE" == "true" ]] && echo "--force") >/dev/null 2>&1 || true
fi
if [[ -x "$INTEL_FETCH_TWITTER" ]]; then
  OSINT_TWITTER_LOOKBACK_MIN="${twitter_lookback_min}" \
    bash "$INTEL_FETCH_TWITTER" $([[ "$FORCE" == "true" ]] && echo "--force") >/dev/null 2>&1 || true
fi

mkdir -p "$(dirname "$SWEEP_STATE")"
mkdir -p "$(dirname "$HISTORY_PATH")"
[[ -f "$HISTORY_PATH" ]] || echo '{}' > "$HISTORY_PATH"
[[ -f "$SWEEP_STATE" ]] || echo '{"last_sweep":"1970-01-01T00:00:00Z"}' > "$SWEEP_STATE"

last_sweep="$(jq -r '.last_sweep // "1970-01-01T00:00:00Z"' "$SWEEP_STATE" 2>/dev/null || echo "1970-01-01T00:00:00Z")"
swept_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

tmp_items="$(mktemp)"
export INTEL_CACHE_RSS INTEL_CACHE_TWITTER
export RSS_ALLOW="$rss_allow"
export TW_ALLOW="$tw_allow"
export TOPIC_WEIGHTS="$topic_weights_json"
export MAJOR_WORDS="$major_keywords_json"
export LAST_SWEEP="$last_sweep"
export NTFY_TH="$ntfy_weight_threshold"
export BREAK_TH="$breaking_score_threshold"
export CROSS_POST="$cross_post_breaking"

# Build items with Python because jq cannot glob files directly without shell support.
python3 - <<'PY' > "$tmp_items"
from __future__ import annotations

import glob
import html
import json
import os
import re
import time
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

cache_rss = Path(os.environ["INTEL_CACHE_RSS"])
cache_tw = Path(os.environ["INTEL_CACHE_TWITTER"])
rss_allow = set(json.loads(os.environ["RSS_ALLOW"]))
tw_allow = set(json.loads(os.environ["TW_ALLOW"]))
weights = json.loads(os.environ["TOPIC_WEIGHTS"])
major = [str(x).lower() for x in json.loads(os.environ["MAJOR_WORDS"])]
last_sweep = os.environ["LAST_SWEEP"]
ntfy_th = float(os.environ["NTFY_TH"])
breaking_th = float(os.environ["BREAK_TH"])
cross_post = os.environ["CROSS_POST"].lower() == "true"
CFP_CACHE_PATH = Path("/tmp/osint_cfp_resolve_cache.json")
CFP_CACHE_TTL_SECONDS = 4 * 60 * 60
EMPTY_CFP_RESOLUTION = {
    "original_source_url": "",
    "original_title": "",
    "original_source_name": "",
}
SOURCE_NAME_MAP = {
    "apnews.com": "AP",
    "nbcnews.com": "NBC News",
    "abcnews.go.com": "ABC News",
    "cnn.com": "CNN",
    "bbc.com": "BBC",
    "bbc.co.uk": "BBC",
    "reuters.com": "Reuters",
    "bloomberg.com": "Bloomberg",
    "wsj.com": "WSJ",
    "nytimes.com": "NYT",
    "washingtonpost.com": "WaPo",
    "foxnews.com": "Fox News",
    "thehill.com": "The Hill",
    "politico.com": "Politico",
    "axios.com": "Axios",
    "theatlantic.com": "The Atlantic",
    "gpb.org": "GPB",
    "georgiarecorder.com": "Georgia Recorder",
    "capitol-beat.org": "Capitol Beat",
    "gapundit.com": "GA Pundit",
}


def load_cfp_cache() -> dict:
    try:
        if CFP_CACHE_PATH.exists():
            data = json.loads(CFP_CACHE_PATH.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
    except Exception:
        pass
    return {}


def save_cfp_cache(cache: dict) -> None:
    try:
        CFP_CACHE_PATH.write_text(json.dumps(cache), encoding="utf-8")
    except Exception:
        pass


cfp_cache: dict = load_cfp_cache()


def fetch_html(url: str, timeout: float = 5.0) -> str:
    if not url:
        return ""
    try:
        req = Request(
            url,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (compatible; nanobot-live-feed/1.0; +https://github.com/philga7/nanobot)"
                )
            },
        )
        with urlopen(req, timeout=timeout) as resp:
            content = resp.read()
            charset = resp.headers.get_content_charset() or "utf-8"
            return content.decode(charset, errors="replace")
    except Exception:
        return ""


def normalize_source_name_from_url(url: str) -> str:
    try:
        host = (urlparse(url).hostname or "").lower()
    except Exception:
        host = ""
    host = host.lstrip("www.")
    if not host:
        return ""
    for domain, label in SOURCE_NAME_MAP.items():
        if host == domain or host.endswith("." + domain):
            return label
    base = host.split(".")
    if len(base) >= 2:
        return base[-2].replace("-", " ").title()
    return host


def extract_first_non_cfp_link(page_html: str) -> str:
    if not page_html:
        return ""
    matches = re.findall(r'href="(https?://[^"]+)"', page_html, flags=re.I)
    for link in matches:
        l = link.strip()
        if not l:
            continue
        low = l.lower()
        if "citizenfreepress.com" in low:
            continue
        return l
    return ""


def extract_og_title(page_html: str) -> str:
    if not page_html:
        return ""
    m = re.search(
        r'<meta[^>]+property=["\']og:title["\'][^>]+content=["\']([^"\']+)["\']',
        page_html,
        flags=re.I,
    )
    if not m:
        m = re.search(
            r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:title["\']',
            page_html,
            flags=re.I,
        )
    if not m:
        return ""
    return html.unescape(m.group(1).strip())


def resolve_cfp_source(cfp_url: str) -> dict:
    if not cfp_url:
        return dict(EMPTY_CFP_RESOLUTION)
    now = time.time()
    cached = cfp_cache.get(cfp_url)
    if isinstance(cached, dict):
        ts = float(cached.get("_cached_at", 0) or 0)
        if now - ts <= CFP_CACHE_TTL_SECONDS:
            return {
                "original_source_url": str(cached.get("original_source_url", "")),
                "original_title": str(cached.get("original_title", "")),
                "original_source_name": str(cached.get("original_source_name", "")),
            }

    result = dict(EMPTY_CFP_RESOLUTION)
    cfp_html = fetch_html(cfp_url, timeout=5.0)
    original_url = extract_first_non_cfp_link(cfp_html)
    if original_url:
        result["original_source_url"] = original_url
        result["original_source_name"] = normalize_source_name_from_url(original_url)
        original_html = fetch_html(original_url, timeout=5.0)
        result["original_title"] = extract_og_title(original_html)

    cfp_cache[cfp_url] = {
        **result,
        "_cached_at": now,
    }
    return result


def norm(s: str) -> str:
    return re.sub(r"[-_]", "", s.lower())


def parse_ts(raw: str | None) -> str:
    if not raw:
        return "1970-01-01T00:00:00Z"
    value = str(raw).strip()
    if value.endswith("Z"):
        return value
    if "T" in value:
        return value + "Z"
    return value + "T00:00:00Z"


def topic_weight(text: str) -> float:
    t = text.lower()
    total = 0.0
    for k, v in weights.items():
        if str(k).lower() in t:
            total += float(v)
    return round(total, 3)


def topic_tags(text: str) -> list[str]:
    t = text.lower()
    tags = [str(k) for k in weights if str(k).lower() in t]
    return sorted(set(tags))


def is_live_rss(title: str) -> bool:
    return bool(re.match(r"^(Watch\s+)?Live\s*\|", title or "", flags=re.I))


def is_live_tweet(text: str) -> bool:
    return bool(re.match(r"^(BREAKING:|LIVE:|🚨)", text or "", flags=re.I))


def major_hit(text: str) -> bool:
    t = (text or "").lower()
    return any(k in t for k in major)


def urgency(is_live: bool, w: float, text: str) -> str:
    if is_live or major_hit(text):
        return "🔴 BREAKING"
    if w >= ntfy_th:
        return "⚡ HIGH"
    return "📰 NEW"


def score(w: float, is_live: bool, pub: str) -> float:
    recency = 2.0 if pub >= last_sweep else 0.5
    return round((w * 1.5) + (2.0 if is_live else 0.0) + recency + 1.0, 2)


items: list[dict] = []

for path in sorted(glob.glob(str(cache_rss / "*.json"))):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        continue
    rows = data if isinstance(data, list) else [data]
    for row in rows:
        if isinstance(row, dict) and "items" in row and isinstance(row["items"], list):
            feed = row
            slug = str(feed.get("id") or feed.get("source") or feed.get("feed") or Path(path).stem)
            if rss_allow and slug not in rss_allow:
                continue
            source_tier = feed.get("tier") or "alternative"
            for it in feed["items"]:
                if not isinstance(it, dict):
                    continue
                title = str(it.get("title") or it.get("headline") or "").strip()
                guid = str(it.get("guid") or it.get("id") or it.get("link") or it.get("url") or "").strip()
                url = str(it.get("url") or it.get("link") or guid).strip()
                pub = parse_ts(it.get("pubDate") or it.get("published") or it.get("pub_date"))
                if not title or not guid:
                    continue
                live = is_live_rss(title)
                w = topic_weight(title)
                s = score(w, live, pub)
                items.append(
                    {
                        "source": slug,
                        "source_tier": source_tier,
                        "type": "rss",
                        "guid": guid,
                        "tweet_id": None,
                        "title": title,
                        "url": url,
                        "pub_date": pub,
                        "category": it.get("category") or feed.get("category"),
                        "is_live": live,
                        "topic_tags": topic_tags(title),
                        "topic_weight": w,
                        "urgency": urgency(live, w, title),
                        "score": s,
                    }
                )
                if slug == "citizen-free-press":
                    items[-1].update(resolve_cfp_source(url))

for path in sorted(glob.glob(str(cache_tw / "*.json"))):
    handle = Path(path).stem
    if tw_allow and handle not in tw_allow:
        continue
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        continue
    rows = data if isinstance(data, list) else [data]
    for it in rows:
        if not isinstance(it, dict):
            continue
        text = str(it.get("text") or it.get("content") or "").strip()
        tweet_id = str(it.get("id") or it.get("tweet_id") or "").strip()
        url = str(it.get("url") or (f"https://x.com/i/web/status/{tweet_id}" if tweet_id else "")).strip()
        pub = parse_ts(it.get("created_at") or it.get("date") or it.get("published"))
        if not text:
            continue
        if not tweet_id:
            m = re.search(r"/status/(\d+)", url)
            tweet_id = m.group(1) if m else ""
        if not tweet_id:
            continue
        live = is_live_tweet(text)
        w = topic_weight(text)
        s = score(w, live, pub)
        items.append(
            {
                "source": handle,
                "source_tier": "alternative",
                "type": "twitter",
                "guid": None,
                "tweet_id": tweet_id,
                "title": text,
                "url": url,
                "pub_date": pub,
                "category": "social",
                "is_live": live,
                "topic_tags": topic_tags(text),
                "topic_weight": w,
                "urgency": urgency(live, w, text),
                "score": s,
            }
        )

items.sort(key=lambda x: x.get("pub_date", ""), reverse=True)
ntfy_items = [i for i in items if i["urgency"] in {"🔴 BREAKING", "⚡ HIGH"}]
cross_post_items = [i for i in items if cross_post and float(i.get("score", 0)) >= breaking_th]
save_cfp_cache(cfp_cache)

print(
    json.dumps(
        {
            "new_count": len(items),
            "items": items,
            "ntfy_items": ntfy_items,
            "cross_post_items": cross_post_items,
        }
    )
)
PY

all_items="$(cat "$tmp_items")"
rm -f "$tmp_items"

filtered_items="$(echo "$all_items" | jq -c --arg ls "$last_sweep" '
  .items
  | map(select((.pub_date // "1970-01-01T00:00:00Z") >= $ls))
')"

new_items='[]'
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  key="$(echo "$row" | jq -r '.guid // .tweet_id // empty')"
  [[ -n "$key" ]] || continue
  seen="$(python3 "$DEDUP_PY" --history "$HISTORY_PATH" --check "$key" 2>/dev/null || echo "new")"
  if [[ "$seen" == "new" ]]; then
    new_items="$(jq -c --argjson item "$row" '. + [$item]' <<<"$new_items")"
  fi
done < <(echo "$filtered_items" | jq -c '.[]')

result="$(
  jq -n \
    --arg swept_at "$swept_at" \
    --argjson items "$new_items" \
    --argjson ntfy_th "$ntfy_weight_threshold" \
    --argjson break_th "$breaking_score_threshold" \
    --argjson cross_post "$cross_post_breaking" '
    {
      swept_at: $swept_at,
      new_count: ($items | length),
      items: $items,
      ntfy_items: ($items | map(select(.urgency == "🔴 BREAKING" or .urgency == "⚡ HIGH"))),
      cross_post_items: (
        if $cross_post then
          ($items | map(select((.score // 0) >= $break_th)))
        else [] end
      )
    }'
)"

if [[ "$DRY_RUN" != "true" ]]; then
  echo "$result" | jq -c '.items[]?' | while IFS= read -r item; do
    key="$(echo "$item" | jq -r '.guid // .tweet_id')"
    [[ -n "$key" ]] || continue
    payload="$(
      echo "$item" | jq -c --arg k "$key" --arg desk "$DESK" --arg ch "$channel_id" '
        {
          key: $k,
          first_seen: (.pub_date // null),
          last_seen: (now | todateiso8601 | sub("\\+00:00$"; "Z")),
          source: .source,
          source_type: .type,
          title: .title,
          desks: [$desk],
          channels: (if ($ch|length) > 0 then [$ch] else [] end),
          score: .score,
          urgency: .urgency
        }
      '
    )"
    printf '%s\n' "$payload" | python3 "$DEDUP_PY" --history "$HISTORY_PATH" --add - >/dev/null 2>&1 || true
  done
  python3 "$DEDUP_PY" --history "$HISTORY_PATH" --prune 7 >/dev/null 2>&1 || true
  jq -n --arg ts "$swept_at" '{last_sweep:$ts}' > "$SWEEP_STATE"
fi

if [[ -n "$JSON_OUT" ]]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  echo "$result" | jq -c . > "$JSON_OUT"
  echo "$JSON_OUT"
  exit 0
fi

echo "$result" | jq .

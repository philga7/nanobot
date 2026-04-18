#!/usr/bin/env bash
# Merge today's raw newsletter JSONs, cross-reference stories, update catalogs,
# write digest + OSINT feed + latest snapshot, optionally post to Slack #ai-ml.
#
# Env:
#   NANOBOT_CHANNELS__SLACK__BOT_TOKEN — Slack bot token (optional)
#   AI_ML_NEWSLETTER_SLACK_CHANNEL — channel ID or name (default #ai-ml)
#   AI_ML_NEWSLETTER_TZ — IANA tz for "today" (default America/New_York)
#   AI_ML_NEWSLETTER_SKIP_SLACK — if 1, skip chat.postMessage

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export AI_ML_NEWSLETTER_SKILL_ROOT="${AI_ML_NEWSLETTER_SKILL_ROOT:-$SKILL_ROOT}"

python3 << 'EOF'
from __future__ import annotations

import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime
from typing import Any
from urllib.parse import parse_qsl, urlparse, urlencode, urlunparse
from zoneinfo import ZoneInfo

SKILL_ROOT = os.environ.get("AI_ML_NEWSLETTER_SKILL_ROOT", "")
CACHE_RAW = os.environ.get(
    "AI_ML_NEWSLETTER_CACHE_RAW",
    os.path.join(SKILL_ROOT, "cache", "raw") if SKILL_ROOT else "",
)
CACHE_STORIES = os.environ.get(
    "AI_ML_NEWSLETTER_CACHE_STORIES",
    os.path.join(SKILL_ROOT, "cache", "stories") if SKILL_ROOT else "",
)
STATE_DIR = os.path.expanduser(
    os.environ.get("AI_ML_NEWSLETTER_STATE_DIR", "~/.wrenvps/ai-ml-newsletter")
)
APPS_PATH = os.path.join(STATE_DIR, "apps-sites.json")
OSINT_PATH = os.path.join(STATE_DIR, "osint_feed.json")
LATEST_PATH = os.path.join(STATE_DIR, "latest-digest.json")

TZ_NAME = os.environ.get("AI_ML_NEWSLETTER_TZ", "America/New_York")
SLACK_CHANNEL = os.environ.get("AI_ML_NEWSLETTER_SLACK_CHANNEL", "#ai-ml")
SLACK_TOKEN = os.environ.get("NANOBOT_CHANNELS__SLACK__BOT_TOKEN", "")
SKIP_SLACK = os.environ.get("AI_ML_NEWSLETTER_SKIP_SLACK", "").strip() in ("1", "true", "yes")

_TRACK_Q = frozenset(
    k.lower()
    for k in (
        "utm_source",
        "utm_medium",
        "utm_campaign",
        "utm_term",
        "utm_content",
        "fbclid",
        "gclid",
        "mc_cid",
        "mc_eid",
    )
)

_STOP_HEADLINE = frozenset(
    """
    the a an or and but in on at to for of is are was were be been being
    it this that these those as by from with into than then so not no
    we you our their its his her they them he she one two new old more most
    """.split()
)


def today_str() -> str:
    return datetime.now(ZoneInfo(TZ_NAME)).strftime("%Y-%m-%d")


def _sponsored_or_section_garbage(headline: str, summary: str) -> bool:
    """Sponsor blocks and Neuron section titles that slip through the parser."""
    hl = (headline or "").lower().strip()
    sm = (summary or "").lower().strip()
    blob = f"{hl} {sm[:220]}"
    if sm.startswith("follow image link") or sm.startswith("follow image:"):
        return True
    if re.search(r"\b(sponsored|brought to you by)\b", blob):
        return True
    neuron_junk = frozenset(
        {
            "treats to try",
            "around the horn",
            "cat's commentary",
            "a cat's commentary",
            "intelligent insights",
            "ai skill of the day",
        }
    )
    if hl in neuron_junk:
        return True
    if "unlock access" in hl and "product" in hl:
        return True
    return False


def is_quality_story(story: dict) -> bool:
    """Drop parser artifacts before clustering."""
    headline = (story.get("headline") or "").lower().strip()
    summary = (story.get("summary") or "").lower().strip()
    if len(headline) < 5:
        return False
    if _sponsored_or_section_garbage(story.get("headline", ""), story.get("summary", "")):
        return False
    garbage_headline = (
        "unsubscribe",
        "view this post",
        "click here",
        "upgrade to paid",
        "share this",
        "navigation",
        "read on the web",
        "disable_email",
        "action/disable",
    )
    if any(p in headline for p in garbage_headline):
        return False
    if headline in ("links", "link", "sponsor", "sponsors"):
        return False
    garbage_summary = (
        "unsubscribe",
        "view this post",
        "click here",
        "upgrade to paid",
        "share this",
        "navigation",
        "read on the web",
        "disable_email",
        "action/disable",
    )
    if any(p in summary[:100] for p in garbage_summary):
        return False
    links = story.get("links") or []
    if not links:
        return False
    real_links = [l for l in links if "substack.com/redirect" not in (l.get("url") or "")]
    if not real_links:
        return False
    return True


def normalize_url(url: str) -> str:
    u = (url or "").strip()
    if not u:
        return ""
    p = urlparse(u.lower())
    q = [(k, v) for k, v in parse_qsl(p.query, keep_blank_values=True) if k.lower() not in _TRACK_Q]
    new_query = urlencode(q)
    path = p.path or ""
    if path.endswith("/"):
        path = path.rstrip("/")
    return urlunparse((p.scheme, p.netloc, path, p.params, new_query, ""))


def headline_tokens(h: str) -> set[str]:
    words = re.findall(r"[a-z0-9]+", (h or "").lower())
    return {w for w in words if w not in _STOP_HEADLINE and len(w) > 2}


def headline_jaccard(a: str, b: str) -> float:
    ta, tb = headline_tokens(a), headline_tokens(b)
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / len(ta | tb)


def title_entities(h: str) -> set[str]:
    return set(re.findall(r"\b[A-Z][a-z][a-zA-Z0-9]*\b", h or ""))


def story_urls(story: dict) -> set[str]:
    urls: set[str] = set()
    for L in story.get("links") or []:
        nu = normalize_url(L.get("url", ""))
        if nu:
            urls.add(nu)
    return urls


def primary_and_types(links: list[dict]) -> tuple[str, str]:
    for L in links or []:
        if L.get("type") == "primary_source" and L.get("url"):
            return L["url"], "primary_source"
    for L in links or []:
        if L.get("type") == "expanded_coverage" and L.get("url"):
            return L["url"], "expanded_coverage"
    for L in links or []:
        if L.get("url"):
            return L["url"], str(L.get("type") or "related")
    return "", "related"


def mergeable(sa: dict, sb: dict) -> bool:
    ua, ub = story_urls(sa), story_urls(sb)
    if ua and ub and (ua & ub):
        return True
    # similar path different host rare — check path overlap
    paths_a = {urlparse(u).path for u in ua if urlparse(u).path and len(urlparse(u).path) > 8}
    paths_b = {urlparse(u).path for u in ub if urlparse(u).path and len(urlparse(u).path) > 8}
    if paths_a & paths_b:
        return True
    j = headline_jaccard(sa.get("headline", ""), sb.get("headline", ""))
    if j >= 0.38:
        return True
    ea, eb = title_entities(sa.get("headline", "")), title_entities(sb.get("headline", ""))
    if j >= 0.22 and ea and eb and (ea & eb):
        return True
    if len(ea & eb) >= 2:
        return True
    return False


def cluster_stories(nodes: list[dict]) -> list[list[int]]:
    n = len(nodes)
    parent = list(range(n))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for i in range(n):
        for j in range(i + 1, n):
            if mergeable(nodes[i], nodes[j]):
                union(i, j)
    buckets: dict[int, list[int]] = defaultdict(list)
    for i in range(n):
        buckets[find(i)].append(i)
    return list(buckets.values())


def slugify(s: str, max_len: int = 48) -> str:
    s2 = re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-")
    return s2[:max_len].rstrip("-") or "story"


def merge_summaries(texts: list[str]) -> str:
    parts = []
    seen = set()
    for t in texts:
        t = re.sub(r"\s+", " ", (t or "").strip())
        if len(t) < 12:
            continue
        key = t[:80].lower()
        if key in seen:
            continue
        seen.add(key)
        parts.append(t)
    merged = " ".join(parts)
    if len(merged) > 1200:
        merged = merged[:1197] + "..."
    return merged


def best_headline(headlines: list[str]) -> str:
    return max(headlines, key=lambda h: len(h or "")) if headlines else "Story"


def story_osint_relevance(headline: str, summary: str) -> str:
    t = f"{headline} {summary}".lower()
    high = re.compile(
        r"\b(china|taiwan|sanction|export control|pentagon|nato|ukraine|iran|"
        r"regulation|congress|senate|white house|geopolitic|military|defense|"
        r"vulnerability|cve|breach|ransomware|exploit|classified)\b"
    )
    if high.search(t):
        return "high"
    high2 = re.compile(
        r"\b(openai|anthropic|google|microsoft|meta|nvidia|apple|amazon|"
        r"sec\b|doj|antitrust|lawsuit)\b"
    )
    if high2.search(t):
        return "high"
    med = re.compile(
        r"\b(launch|release|paper|research|arxiv|benchmark|model|"
        r"breakthrough|funding|series [a-z])\b"
    )
    if med.search(t):
        return "medium"
    return "low"


def app_osint_relevance(name: str, desc: str, category: str) -> str:
    blob = f"{name} {desc} {category}".lower()
    if re.search(r"\b(api|platform|security|defense|gov)\b", blob):
        return "medium"
    return "low"


def slack_sanitize_user_text(s: str) -> str:
    """Strip characters that break Slack mrkdwn (*bold*, _italic_, links)."""
    return (s or "").replace("*", "·").replace("`", "ʼ").replace("_", "·").replace("|", "·")


def slack_sanitize_link_label(s: str, max_len: int = 72) -> str:
    s = (s or "link").replace("|", "·").replace("<", "").replace(">", "")
    s = re.sub(r"\s+", " ", s).strip() or "link"
    if len(s) > max_len:
        return s[: max_len - 1] + "…"
    return s


def slack_mrkdwn_link(url: str, label: str) -> str:
    u = (url or "").strip().rstrip(").,;]")
    if not u:
        return ""
    lab = slack_sanitize_link_label(label, 72)
    return f"<{u}|{lab}>"


def slack_type_link_label(link_type: str) -> str:
    t = (link_type or "link").replace("_", " ").strip() or "link"
    return t[:36] + ("…" if len(t) > 36 else "")


def slack_linkify_plain_urls(text: str, max_urls: int = 12) -> str:
    if not text:
        return ""
    out: list[str] = []
    pos = 0
    n = 0
    for m in re.finditer(r"https?://[^\s<>\]|]+", text):
        if m.start() > 0 and text[m.start() - 1] == "<":
            continue
        out.append(text[pos : m.start()])
        if n >= max_urls:
            out.append(m.group(0))
            pos = m.end()
            continue
        raw_u = m.group(0).rstrip(").,;]")
        host = urlparse(raw_u).netloc or "link"
        out.append(slack_mrkdwn_link(raw_u, host))
        pos = m.end()
        n += 1
    out.append(text[pos:])
    return "".join(out)


def md_to_slack(s: str) -> str:
    if not s:
        return ""

    def _md_link(m: re.Match[str]) -> str:
        return slack_mrkdwn_link(m.group(2), m.group(1))

    s = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", _md_link, s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"*\1*", s)
    return s


def slack_section_divider() -> str:
    return "· · · · · · · · · ·"


def build_slack_digest(date: str, merged_stories: list[dict], apps: list[dict]) -> str:
    lines: list[str] = [
        f"🤖 *AI/ML Daily Digest* — {date}",
        "",
        f"📰 *TOP STORIES* ({len(merged_stories)} items)",
        "",
    ]
    merged_stories = sorted(
        merged_stories,
        key=lambda s: (-s.get("coverage_count", 1), s.get("headline", "")),
    )
    for i, st in enumerate(merged_stories[:35], 1):
        cc = st.get("coverage_count", 1)
        hl = slack_sanitize_user_text(st.get("headline", ""))
        summ = (st.get("summary") or "").strip()
        summ = re.sub(r"\s+", " ", summ)[:750]
        srcs = st.get("sources") or []
        names = ", ".join(
            slack_sanitize_user_text(s.get("newsletter", "") or "")
            for s in srcs
            if s.get("newsletter")
        )
        woven = summ
        for s in srcs[:3]:
            lk = (s.get("link") or "").strip()
            nn = slack_sanitize_user_text(s.get("newsletter", "") or "")
            if lk and nn:
                tag = slack_mrkdwn_link(lk, nn)
                if tag not in woven:
                    woven += f" _See also ({nn}):_ {tag}"
        woven = md_to_slack(woven)
        woven = slack_linkify_plain_urls(woven, max_urls=10)
        if cc > 1:
            lines.append(f"*{i}. {hl}* · _{cc} sources_")
        else:
            one = slack_sanitize_user_text(
                (srcs[0].get("newsletter") or "newsletter") if srcs else "newsletter"
            )
            lines.append(f"*{i}. {hl}* · _1 source — {one}_")
        lines.append(woven)
        all_links = st.get("links") or []
        if all_links:
            parts = [
                slack_mrkdwn_link(L.get("url", ""), slack_type_link_label(str(L.get("type") or "link")))
                for L in all_links[:5]
                if L.get("url")
            ]
            parts = [p for p in parts if p]
            if parts:
                lines.append("→ " + " · ".join(parts))
        if cc > 1 and names:
            lines.append(f"_Also covered by:_ {names}")
        lines.append("")

    lines.append(slack_section_divider())
    lines.append("")
    lines.append("🔧 *NOTABLE APPS & SITES*")
    lines.append("")
    for a in apps[:60]:
        nm = slack_sanitize_user_text(a.get("name", "") or "")
        url = (a.get("url") or "").strip()
        desc_full = (a.get("description") or "").strip() or (a.get("name") or "")
        desc_fmt = slack_sanitize_user_text(desc_full)
        desc_fmt = md_to_slack(desc_fmt)
        desc_fmt = slack_linkify_plain_urls(desc_fmt, max_urls=4)
        lines.append(f"• *{nm}* — {desc_fmt}")
        if url:
            lines.append(
                f"  → {slack_mrkdwn_link(url, urlparse(url).netloc or 'link')}"
            )
    lines.append("")
    lines.append(slack_section_divider())
    lines.append("")
    lines.append("📊 *COVERAGE MAP*")
    lines.append("")
    for st in merged_stories[:35]:
        hl = slack_sanitize_user_text((st.get("headline") or "")[:80])
        srcs = st.get("sources") or []
        nms = ", ".join(slack_sanitize_user_text(s.get("newsletter") or "?") for s in srcs)
        lines.append(f"• *{hl}* — _{nms}_")
    return "\n".join(lines)


def trim_to_words(text: str, max_words: int = 1500) -> str:
    words = text.split()
    if len(words) <= max_words:
        return text
    return " ".join(words[:max_words]) + "\n\n_(Digest truncated to ~1500 words.)_"


def slack_post_chunks(text: str, limit: int = 3500) -> list[str]:
    if len(text) <= limit:
        return [text]
    chunks = []
    buf = []
    size = 0
    for para in text.split("\n\n"):
        p = para + "\n\n"
        if size + len(p) > limit and buf:
            chunks.append("".join(buf).rstrip())
            buf = [p]
            size = len(p)
        else:
            buf.append(p)
            size += len(p)
    if buf:
        chunks.append("".join(buf).rstrip())
    return chunks


def post_slack(channel: str, text: str) -> None:
    if not SLACK_TOKEN:
        print("Slack: NANOBOT_CHANNELS__SLACK__BOT_TOKEN not set; skip post", file=sys.stderr)
        return
    for chunk in slack_post_chunks(text):
        payload = json.dumps({"channel": channel, "text": chunk}).encode("utf-8")
        req = urllib.request.Request(
            "https://slack.com/api/chat.postMessage",
            data=payload,
            headers={
                "Authorization": f"Bearer {SLACK_TOKEN}",
                "Content-Type": "application/json; charset=utf-8",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read().decode("utf-8", errors="replace"))
        except urllib.error.URLError as e:
            print(f"Slack post failed: {e}", file=sys.stderr)
            return
        if not body.get("ok"):
            print(f"Slack API error: {body}", file=sys.stderr)


def load_apps_catalog() -> dict[str, Any]:
    try:
        with open(APPS_PATH, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"last_updated": "", "apps_sites": []}


def update_apps_catalog_batch(date: str, new_items: list[dict]) -> dict[str, Any]:
    data = load_apps_catalog()
    by_url: dict[str, dict] = {}
    for x in data.get("apps_sites", []):
        u = (x.get("url") or "").lower()
        if u:
            by_url[u] = x
    for a in new_items:
        url = (a.get("url") or "").strip()
        if not url:
            continue
        key = url.lower()
        nl = (a.get("_newsletter") or "")[:120]
        if key in by_url:
            by_url[key]["times_mentioned"] = int(by_url[key].get("times_mentioned") or 1) + 1
            continue
        by_url[key] = {
            "name": a.get("name", "")[:200],
            "url": url,
            "description": (a.get("description") or "")[:500],
            "category": a.get("category") or "tool",
            "first_seen": date,
            "first_seen_in": nl,
            "times_mentioned": 1,
        }
    data["last_updated"] = date
    data["apps_sites"] = sorted(by_url.values(), key=lambda z: (z.get("name") or "").lower())
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(APPS_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    return data


def main() -> int:
    if not CACHE_RAW or not os.path.isdir(CACHE_RAW):
        print(f"ERROR: cache raw dir missing: {CACHE_RAW}", file=sys.stderr)
        return 1
    os.makedirs(CACHE_STORIES, exist_ok=True)

    d = today_str()
    pattern = os.path.join(CACHE_RAW, f"*_{d}.json")
    paths = sorted(glob.glob(pattern))
    if not paths:
        print(f"No raw files for {d} in {CACHE_RAW} — writing empty digest.", flush=True)

    flat: list[dict] = []
    all_apps: list[dict] = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                raw = json.load(f)
        except json.JSONDecodeError as e:
            print(f"WARNING: skip bad JSON {path}: {e}", file=sys.stderr)
            continue
        nl = raw.get("newsletter", "unknown")
        dt = raw.get("date", d)
        for s in raw.get("stories") or []:
            flat.append({**s, "_newsletter": nl, "_date": dt, "_raw_path": path})
        for a in raw.get("notable_apps_sites") or []:
            all_apps.append({**a, "_newsletter": nl})

    flat = [s for s in flat if is_quality_story(s)]

    clusters = cluster_stories(flat) if flat else []
    merged_stories: list[dict] = []

    for group in clusters:
        members = [flat[i] for i in group]
        headlines = [m.get("headline", "") for m in members]
        hl = best_headline(headlines)
        sid = f"{slugify(hl)}-{d}"
        summaries = [m.get("summary", "") for m in members]
        summary = merge_summaries(summaries)
        sources = []
        link_map: dict[str, dict] = {}
        cats: set[str] = set()
        for m in members:
            nl = m.get("_newsletter", "")
            dt = m.get("_date", d)
            src_h = m.get("headline", "")
            pl, _ = primary_and_types(m.get("links") or [])
            if not pl:
                urls = list(story_urls(m))
                pl = urls[0] if urls else ""
            sources.append(
                {
                    "newsletter": nl,
                    "date": dt,
                    "headline": src_h,
                    "link": pl,
                }
            )
            for L in m.get("links") or []:
                u = normalize_url(L.get("url", ""))
                if not u:
                    continue
                if u not in link_map:
                    link_map[u] = {
                        "url": L.get("url"),
                        "context": L.get("context", "")[:240],
                        "type": L.get("type") or "related",
                    }
            for c in m.get("categories") or []:
                cats.add(str(c))

        merged_stories.append(
            {
                "story_id": sid,
                "headline": hl,
                "summary": summary,
                "sources": sources,
                "links": list(link_map.values())[:24],
                "coverage_count": len(sources),
                "categories": sorted(cats),
            }
        )

    digest_doc = {
        "date": d,
        "generated_at": datetime.now(ZoneInfo(TZ_NAME)).isoformat(),
        "story_count": len(merged_stories),
        "stories": merged_stories,
    }
    digest_path = os.path.join(CACHE_STORIES, f"daily_digest_{d}.json")
    with open(digest_path, "w", encoding="utf-8") as f:
        json.dump(digest_doc, f, indent=2)
    print(f"Wrote {digest_path}", flush=True)

    # Apps catalog: merge today's picks
    seen_app_url: set[str] = set()
    dedup_apps: list[dict] = []
    for a in all_apps:
        u = (a.get("url") or "").lower()
        if not u or u in seen_app_url:
            continue
        seen_app_url.add(u)
        dedup_apps.append(
            {
                "name": a.get("name", ""),
                "url": a.get("url", ""),
                "description": a.get("description", ""),
                "category": a.get("category", "tool"),
                "_newsletter": a.get("_newsletter", ""),
            }
        )
    apps_catalog = update_apps_catalog_batch(d, dedup_apps)

    osint_stories = []
    for st in merged_stories:
        links = [L.get("url") for L in st.get("links") or [] if L.get("url")]
        osint_stories.append(
            {
                "headline": st.get("headline", ""),
                "summary": st.get("summary", ""),
                "categories": st.get("categories", []),
                "links": links[:20],
                "coverage_count": st.get("coverage_count", 1),
                "osint_relevance": story_osint_relevance(st.get("headline", ""), st.get("summary", "")),
            }
        )
    osint_apps = []
    for a in dedup_apps:
        osint_apps.append(
            {
                "name": a.get("name", ""),
                "url": a.get("url", ""),
                "category": a.get("category", ""),
                "osint_relevance": app_osint_relevance(
                    a.get("name", ""), a.get("description", ""), a.get("category", "")
                ),
            }
        )
    osint_doc = {"date": d, "stories": osint_stories, "apps_sites": osint_apps}
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(OSINT_PATH, "w", encoding="utf-8") as f:
        json.dump(osint_doc, f, indent=2)
    print(f"Wrote {OSINT_PATH}", flush=True)

    slack_text = build_slack_digest(d, merged_stories, dedup_apps)
    slack_text = trim_to_words(slack_text, 1500)

    latest = {
        "date": d,
        "digest_path": digest_path,
        "slack_text": slack_text,
        "story_count": len(merged_stories),
        "apps_catalog_path": APPS_PATH,
        "apps_catalog_count": len(apps_catalog.get("apps_sites", [])),
    }
    with open(LATEST_PATH, "w", encoding="utf-8") as f:
        json.dump(latest, f, indent=2)
    print(f"Wrote {LATEST_PATH}", file=sys.stderr)

    if not SKIP_SLACK:
        post_slack(SLACK_CHANNEL, slack_text)
    else:
        print("Slack skipped (AI_ML_NEWSLETTER_SKIP_SLACK)", flush=True)

    return 0


raise SystemExit(main())
EOF

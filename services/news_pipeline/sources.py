"""Source fetchers: CFP RSS, bird-api, SearXNG, NWS, Gold API."""

from __future__ import annotations

import os
import xml.etree.ElementTree as ET
from typing import Any

import httpx
from datetime import datetime, timezone

from .models import MarketAlert, NewsItem, WeatherEvent

SEARXNG_BASE = os.environ.get("SEARXNG_BASE_URL", "http://searxng:8080")
BIRD_API_BASE = os.environ.get("BIRD_API_BASE_URL", "http://bird-api:18791")
GOLD_API_BASE = "https://gold-api.com"
HTTP_TIMEOUT = 15


def _get(url: str, params: dict | None = None) -> httpx.Response:
    return httpx.get(url, params=params, timeout=HTTP_TIMEOUT, follow_redirects=True)


# ── CFP RSS ──────────────────────────────────────────────────────────────────

def fetch_cfp(source: dict[str, Any]) -> list[NewsItem]:
    """Parse Citizen Free Press RSS feed, flag breaking/live items."""
    items: list[NewsItem] = []
    try:
        resp = _get(source["url"])
        resp.raise_for_status()
    except httpx.HTTPError:
        return items

    root = ET.fromstring(resp.text)
    track = {l.lower() for l in source.get("trackLabels", ["breaking", "live"])}

    for entry in root.iter("item"):
        title = (entry.findtext("title") or "").strip()
        link = (entry.findtext("link") or "").strip()
        pub = (entry.findtext("pubDate") or "").strip()
        cats = [c.text.strip() for c in entry.findall("category") if c.text]

        title_lower = title.lower()
        cats_lower = {c.lower() for c in cats}
        has_breaking = "breaking" in title_lower or "breaking" in cats_lower
        has_live = "live" in title_lower or "live" in cats_lower

        if track and not (has_breaking or has_live):
            if not (track & cats_lower):
                continue

        items.append(NewsItem(
            title=title, url=link, source_kind="cfp",
            published=pub, categories=cats,
            delivery=source.get("delivery", {}),
            has_breaking_label=has_breaking, has_live_label=has_live,
        ))
    return items


# ── Generic RSS (any feed) ───────────────────────────────────────────────────

def fetch_rss(source: dict[str, Any]) -> list[NewsItem]:
    """Parse any RSS/Atom feed; no breaking/live logic."""
    items: list[NewsItem] = []
    try:
        resp = _get(source["url"])
        resp.raise_for_status()
    except httpx.HTTPError:
        return items

    root = ET.fromstring(resp.text)
    ns = {"atom": "http://www.w3.org/2005/Atom", "dc": "http://purl.org/dc/elements/1.1/"}
    ATOM = "http://www.w3.org/2005/Atom"

    # RSS 2.0 <item>
    for entry in root.iter("item"):
        title = (entry.findtext("title") or "").strip()
        link = (entry.findtext("link") or "").strip()
        pub = (entry.findtext("pubDate") or entry.findtext("dc:date", namespaces=ns) or "").strip()
        cats = [c.text.strip() for c in entry.findall("category") if c.text]
        desc = (entry.findtext("description") or "").strip()[:500]
        if title or link:
            items.append(NewsItem(
                title=title, url=link, source_kind="rss",
                published=pub, categories=cats, snippet=desc,
                delivery=source.get("delivery", {}),
            ))

    # Atom <entry> (only if no RSS items found)
    if not items:
        for entry in root.iter(f"{{{ATOM}}}entry"):
            title_el = entry.find(f"{{{ATOM}}}title") or entry.find("title")
            title = (title_el.text or "").strip() if title_el is not None else ""
            link_el = entry.find(f"{{{ATOM}}}link") or entry.find("link")
            link = link_el.get("href", "") if link_el is not None else ""
            pub_el = entry.find(f"{{{ATOM}}}published") or entry.find("published")
            pub = (pub_el.text or "").strip() if pub_el is not None else ""
            cats = []
            for c in entry.findall(f"{{{ATOM}}}category") or entry.findall("category"):
                if c.text:
                    cats.append(c.text.strip())
            sum_el = entry.find(f"{{{ATOM}}}summary") or entry.find("summary")
            desc = ((sum_el.text or "").strip()[:500]) if sum_el is not None else ""
            if title or link:
                items.append(NewsItem(
                    title=title, url=link, source_kind="rss",
                    published=pub, categories=cats, snippet=desc,
                    delivery=source.get("delivery", {}),
                ))
    return items


# ── bird-api (X / Twitter) ──────────────────────────────────────────────────

def fetch_bird(source: dict[str, Any]) -> list[NewsItem]:
    """Fetch recent tweets from a profile via bird-api."""
    handle = source.get("handle", "")
    limit = min(source.get("lookbackMinutes", 60) // 3, 20)
    must = [m.lower() for m in source.get("mustMatch", [])]
    items: list[NewsItem] = []
    try:
        resp = _get(f"{BIRD_API_BASE}/timeline", params={"handle": f"@{handle}", "limit": limit})
        resp.raise_for_status()
        data = resp.json()
    except (httpx.HTTPError, ValueError):
        return items

    tweets = data if isinstance(data, list) else data.get("tweets", data.get("results", []))
    for tw in tweets:
        text = tw.get("text", tw.get("full_text", ""))
        if must and not any(m in text.lower() for m in must):
            continue
        url = tw.get("url", f"https://x.com/{handle}/status/{tw.get('id', '')}")
        items.append(NewsItem(
            title=text[:200], url=url, source_kind="bird",
            published=tw.get("created_at", ""),
            delivery=source.get("delivery", {}),
            has_breaking_label=any(w in text.lower() for w in ("breaking", "alert")),
            has_live_label="live" in text.lower(),
            raw=tw,
        ))
    return items


# ── SearXNG ──────────────────────────────────────────────────────────────────

def fetch_searxng(source: dict[str, Any]) -> list[NewsItem]:
    """Run a SearXNG search and normalize results."""
    params: dict[str, Any] = {
        "q": source.get("query", ""),
        "format": "json",
        "categories": ",".join(source.get("engines", ["news"])),
    }
    items: list[NewsItem] = []
    try:
        resp = _get(f"{SEARXNG_BASE}/search", params=params)
        resp.raise_for_status()
        data = resp.json()
    except (httpx.HTTPError, ValueError):
        return items

    for r in data.get("results", [])[:source.get("maxResults", 10)]:
        items.append(NewsItem(
            title=r.get("title", ""),
            url=r.get("url", ""),
            source_kind="searxng",
            snippet=r.get("content", ""),
            published=r.get("publishedDate", ""),
            delivery=source.get("delivery", {}),
        ))
    return items


# ── NWS Alerts ───────────────────────────────────────────────────────────────

def fetch_nws_alerts(job: dict[str, Any]) -> list[WeatherEvent]:
    """Fetch active NWS alerts for configured locations."""
    events: list[WeatherEvent] = []
    for loc in job.get("locations", []):
        zone_url = f"https://api.weather.gov/alerts/active?point={loc['lat']},{loc['lon']}"
        try:
            resp = httpx.get(zone_url, timeout=HTTP_TIMEOUT, headers={"User-Agent": "nanobot-news-pipeline"})
            resp.raise_for_status()
            data = resp.json()
        except (httpx.HTTPError, ValueError):
            continue

        for feat in data.get("features", []):
            props = feat.get("properties", {})
            events.append(WeatherEvent(
                event_type=props.get("event", ""),
                location=loc["name"],
                headline=props.get("headline", ""),
                description=props.get("description", "")[:500],
                severity=props.get("severity", ""),
                onset=props.get("onset", ""),
                expires=props.get("expires", ""),
                nws_id=props.get("id", feat.get("id", "")),
                raw=props,
            ))
    return events


def _nws_points(lat: float, lon: float) -> str | None:
    """Return NWS forecast URL for a point (lat, lon)."""
    url = f"https://api.weather.gov/points/{lat},{lon}"
    try:
        resp = httpx.get(url, timeout=HTTP_TIMEOUT, follow_redirects=True, headers={"User-Agent": "nanobot-news-pipeline"})
        resp.raise_for_status()
        data = resp.json()
    except (httpx.HTTPError, ValueError):
        return None
    props = data.get("properties", {})
    forecast_url = props.get("forecast")
    return forecast_url


def _pick_next_7_days(periods: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Pick one period per day for the next 7 days."""
    now = datetime.now(timezone.utc)
    chosen: dict[str, dict[str, Any]] = {}
    for p in periods:
        start = p.get("startTime") or ""
        if not start:
            continue
        # NWS uses ISO 8601 with Z; be tolerant if it doesn't parse cleanly.
        day = start[:10]
        try:
            dt = datetime.fromisoformat(start.replace("Z", "+00:00"))
        except ValueError:
            continue
        if dt < now:
            continue
        if day not in chosen:
            chosen[day] = p
        if len(chosen) >= 7:
            break
    # Sort by day
    return [chosen[k] for k in sorted(chosen.keys())][:7]


def fetch_nws_weekly_forecast(job: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    """Return per-location daily forecast periods (max 7 each)."""
    out: dict[str, list[dict[str, Any]]] = {}
    for loc in job.get("locations", []):
        forecast_url = _nws_points(float(loc["lat"]), float(loc["lon"]))
        if not forecast_url:
            continue
        try:
            resp = httpx.get(
                forecast_url,
                timeout=HTTP_TIMEOUT,
                follow_redirects=True,
                headers={"User-Agent": "nanobot-news-pipeline"},
            )
            resp.raise_for_status()
            data = resp.json()
        except (httpx.HTTPError, ValueError):
            continue
        properties = data.get("properties", {})
        periods = data.get("periods", []) or properties.get("periods", [])
        out[loc["name"]] = _pick_next_7_days(periods)
    return out


def fetch_searxng_commentary_sources(sources: list[dict[str, Any]]) -> list[NewsItem]:
    """Run SearXNG sources and return a flattened list of NewsItem hits."""
    items: list[NewsItem] = []
    for s in sources:
        if s.get("kind") != "searxngQuery":
            continue
        items.extend(fetch_searxng(s))
    return items


# ── Gold API ─────────────────────────────────────────────────────────────────

def fetch_gold_api(job: dict[str, Any]) -> list[MarketAlert]:
    """Fetch current prices from Gold API for configured assets."""
    api_base = job.get("apiBaseUrl", GOLD_API_BASE)
    alerts: list[MarketAlert] = []
    rules = job.get("alertRules", {})

    for asset in job.get("assets", []):
        symbol = asset["symbol"]
        try:
            resp = _get(f"{api_base}/api/price/{symbol}")
            resp.raise_for_status()
            data = resp.json()
        except (httpx.HTTPError, ValueError):
            continue

        price = data.get("price", data.get("current_price", 0.0))
        if not price:
            continue

        change_pct = data.get("change_pct", data.get("ch", 0.0))
        key_broken = None
        for lvl in asset.get("keyLevels", []):
            if abs(price - lvl) / lvl < 0.005:
                key_broken = lvl
                break

        threshold = rules.get("percentMoveThreshold", 2.0)
        if abs(change_pct) < threshold and key_broken is None:
            continue

        alerts.append(MarketAlert(
            symbol=symbol, label=asset.get("label", symbol),
            price=price, change_pct=change_pct,
            key_level_broken=key_broken, raw=data,
            delivery=asset.get("delivery", {}),
        ))
    return alerts


# ── Dispatcher ───────────────────────────────────────────────────────────────

SOURCE_MAP = {
    "citizenfreepressFeed": fetch_cfp,
    "rssFeed": fetch_rss,
    "birdProfile": fetch_bird,
    "searxngQuery": fetch_searxng,
}


def fetch_news_sources(job: dict[str, Any]) -> list[NewsItem]:
    """Fetch from all sources configured for a news job."""
    items: list[NewsItem] = []
    for src in job.get("sources", []):
        handler = SOURCE_MAP.get(src.get("kind", ""))
        if handler:
            items.extend(handler(src))
    return items

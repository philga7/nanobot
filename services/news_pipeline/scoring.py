"""Scoring engine, OSINT tagger, and topic filtering."""

from __future__ import annotations

from typing import Any

from .config import load_scoring, load_topics
from .models import MarketAlert, NewsItem, WeatherEvent


def _match_keywords(text: str, kw_map: dict[str, list[str]]) -> list[str]:
    """Return OSINT tags whose keywords appear in text."""
    lower = text.lower()
    return [tag for tag, keywords in kw_map.items() if any(k in lower for k in keywords)]


def _impact_scores(tags: list[str]) -> dict[str, float]:
    """Rough impact per dimension based on matched OSINT tags."""
    dim_map = {
        "market": {"markets", "centralBanks", "sanctions", "energy"},
        "security": {"domesticSecurity", "defense", "cyber", "geopolitics"},
        "policy": {"elections", "geopolitics", "sanctions", "infrastructure"},
    }
    result: dict[str, float] = {}
    tag_set = set(tags)
    for dim, relevant in dim_map.items():
        overlap = tag_set & relevant
        result[dim] = min(10.0, len(overlap) * 3.5)
    return result


def _topic_boost(text: str) -> float:
    """Sum weighted boosts for each preferred topic found in text."""
    topics = load_topics()
    lower = text.lower()
    boost = 0.0
    for entry in topics.get("preferred", []):
        if entry["topic"].lower() in lower:
            boost += entry.get("weight", 1.0)
    return boost


def is_ignored(text: str) -> bool:
    """Return True if text matches any ignored topic."""
    topics = load_topics()
    lower = text.lower()
    return any(ign.lower() in lower for ign in topics.get("ignored", []))


def score_news_item(item: NewsItem, job: dict[str, Any]) -> NewsItem:
    scoring = load_scoring()
    profile = scoring.get("profiles", {}).get(job.get("scoringProfile", "breakingNews"), {})
    weights = profile.get("weights", {})
    osint_cfg = scoring.get("osint", {})
    news_tuning = scoring.get("tuning", {}).get("news", {})
    coeffs = news_tuning.get("coefficients", {})

    text = f"{item.title} {item.snippet} {' '.join(item.categories)}"
    item.osint_tags = _match_keywords(text, osint_cfg.get("keywordMap", {}))
    item.impact = _impact_scores(item.osint_tags)

    topic_boost = _topic_boost(text)

    raw_score = 0.0
    raw_score += weights.get("sourceReliability", 1) * coeffs.get("sourceReliability", 0.5)
    raw_score += weights.get("topicPriority", 1) * topic_boost * coeffs.get("topicPriority", 1.0)
    raw_score += weights.get("breakingFlag", 1) * (coeffs.get("breakingFlagMain", 1.0) if item.has_breaking_label else 0.0)
    raw_score += weights.get("breakingFlag", 1) * (coeffs.get("breakingFlagLive", 0.8) if item.has_live_label else 0.0)
    raw_score += weights.get("recency", 1) * coeffs.get("recency", 0.3)
    div = coeffs.get("osintImpactDivisor", 15.0) or 15.0
    raw_score += weights.get("osintImpact", 1) * (sum(item.impact.values()) / div)

    item.score = round(raw_score, 1)
    item.is_breaking = item.score >= profile.get("breakingThreshold", 10)
    return item


def score_weather_event(event: WeatherEvent, job: dict[str, Any]) -> WeatherEvent:
    scoring = load_scoring()
    profile = scoring.get("profiles", {}).get(job.get("scoringProfile", "severeWeather"), {})
    weights = profile.get("weights", {})
    wx_tuning = scoring.get("tuning", {}).get("weather", {})
    severity_map = wx_tuning.get("severityMap", {
        "Extreme": 1.0,
        "Severe": 0.75,
        "Moderate": 0.5,
        "Minor": 0.2,
        "Unknown": 0.3,
    })
    type_map = wx_tuning.get("typeMap", {
        "Tornado Warning": 1.0, "Severe Thunderstorm Warning": 0.8,
        "Flash Flood Warning": 0.75, "Flood Warning": 0.5,
        "Winter Storm Warning": 0.6, "Blizzard Warning": 0.7,
        "Tornado Watch": 0.5, "Severe Thunderstorm Watch": 0.4,
    })
    coeffs = wx_tuning.get("coefficients", {})

    sev_factor = severity_map.get(event.severity, 0.3)
    type_factor = type_map.get(event.event_type, 0.15)

    topic_boost = _topic_boost(f"{event.event_type} {event.location} {event.headline}")

    raw_score = 0.0
    raw_score += weights.get("warningType", 1) * type_factor * coeffs.get("warningTypeScale", 3.3)
    raw_score += weights.get("spatialOverlap", 1) * sev_factor * coeffs.get("spatialOverlapScale", 1.5)
    raw_score += weights.get("modelAgreement", 1) * coeffs.get("modelAgreementScale", 0.5)
    raw_score += topic_boost * coeffs.get("topicBoostScale", 0.5)

    # Optional parameter-based bumps for explicit trigger thresholds.
    # NWS alerts can include a `parameters` object with wind/hail magnitudes.
    params = (event.raw or {}).get("parameters", {}) or {}
    wind = params.get("windSpeed") or params.get("windSpeedMaximum") or {}
    hail = params.get("hailSize") or params.get("hailMaximum") or params.get("hailAmount") or {}

    def _to_float(v: Any) -> float | None:
        try:
            if v is None:
                return None
            if isinstance(v, (int, float)):
                return float(v)
            if isinstance(v, str):
                return float(v)
        except ValueError:
            return None
        return None

    wind_val = wind.get("value") if isinstance(wind, dict) else wind
    wind_mph = _to_float(wind_val)
    if isinstance(wind, dict):
        unit = wind.get("unitCode") or wind.get("unit") or ""
        if isinstance(unit, str) and unit.lower().endswith("m/s") and wind_mph is not None:
            wind_mph = wind_mph * 2.23694

    hail_val = hail.get("value") if isinstance(hail, dict) else hail
    hail_in = _to_float(hail_val)
    if isinstance(hail, dict):
        unit = hail.get("unitCode") or hail.get("unit") or ""
        # Convert mm -> inches if needed.
        if isinstance(unit, str) and "mm" in unit.lower() and hail_in is not None:
            hail_in = hail_in / 25.4

    if wind_mph is not None and wind_mph >= coeffs.get("windMphThreshold", 50):
        raw_score += float(coeffs.get("windMphBonus", 1.0))
    if hail_in is not None and hail_in >= coeffs.get("hailInchThreshold", 1.0):
        raw_score += float(coeffs.get("hailInchBonus", 1.0))

    event.score = round(raw_score, 1)
    event.is_breaking = event.score >= profile.get("breakingThreshold", 8)
    return event


def score_market_alert(alert: MarketAlert, job: dict[str, Any]) -> MarketAlert:
    scoring = load_scoring()
    profile = scoring.get("profiles", {}).get(job.get("scoringProfile", "metals"), {})
    weights = profile.get("weights", {})
    osint_cfg = scoring.get("osint", {})
    mkt_tuning = scoring.get("tuning", {}).get("markets", {})
    coeffs = mkt_tuning.get("coefficients", {})

    alert.osint_tags = _match_keywords(alert.label, osint_cfg.get("keywordMap", {}))
    topic_boost = _topic_boost(alert.label)

    raw_score = 0.0
    raw_score += weights.get("percentMove", 1) * min(3.0, abs(alert.change_pct) / coeffs.get("percentMoveScale", 1.0))
    raw_score += weights.get("keyLevel", 1) * (coeffs.get("keyLevelBonus", 2.0) if alert.key_level_broken else 0.0)
    raw_score += weights.get("velocity", 1) * min(1.5, abs(alert.change_pct) * coeffs.get("velocityScale", 0.5))
    raw_score += topic_boost * coeffs.get("topicBoostScale", 1.0)

    alert.score = round(raw_score, 1)
    alert.is_breaking = alert.score >= profile.get("breakingThreshold", 10)
    return alert

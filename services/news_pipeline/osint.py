"""OSINT context generation: analyst notes and dossiers."""

from __future__ import annotations

from .models import MarketAlert, NewsItem, WeatherEvent
from .config import load_scoring


def _short_note(title: str, tags: list[str], impact: dict[str, float]) -> str:
    """Generate a 1-2 sentence analyst note."""
    if not tags:
        return ""
    top_dim = max(impact, key=impact.get, default="") if impact else ""
    tag_str = ", ".join(tags[:3])
    note = f"Relevant to {tag_str}."
    if top_dim and impact.get(top_dim, 0) >= 3.0:
        note += f" Elevated {top_dim} impact."
    return note


def _dossier(title: str, tags: list[str], impact: dict[str, float], snippet: str = "") -> str:
    """Generate a multi-paragraph dossier for high-score items."""
    sections = []
    tag_str = ", ".join(tags) if tags else "general"
    sections.append(f"OSINT DOSSIER: {title}")
    sections.append(f"Classification: {tag_str}")

    if impact:
        dim_lines = [f"  {d}: {v:.1f}/10" for d, v in sorted(impact.items(), key=lambda x: -x[1])]
        sections.append("Impact Assessment:\n" + "\n".join(dim_lines))

    if snippet:
        sections.append(f"Summary: {snippet[:300]}")

    sections.append(
        "Open Questions: What are the second-order effects? "
        "Which actors are most likely to respond? "
        "What is the timeline for escalation or resolution?"
    )
    return "\n\n".join(sections)


def enrich_news(item: NewsItem, osint_profile: str) -> NewsItem:
    item.analyst_note = _short_note(item.title, item.osint_tags, item.impact)
    if osint_profile == "dossier":
        scoring = load_scoring()
        news_tuning = scoring.get("tuning", {}).get("news", {})
        threshold = news_tuning.get("dossierThreshold", 10.0)
        if item.score >= threshold:
            item.dossier = _dossier(item.title, item.osint_tags, item.impact, item.snippet)
    return item


def enrich_weather(event: WeatherEvent, osint_profile: str) -> WeatherEvent:
    event.analyst_note = f"{event.event_type} for {event.location}. Severity: {event.severity}."
    return event


def enrich_market(alert: MarketAlert, osint_profile: str) -> MarketAlert:
    direction = "up" if alert.change_pct > 0 else "down"
    alert.analyst_note = f"{alert.label} moved {abs(alert.change_pct):.1f}% {direction} to ${alert.price:,.2f}."
    if alert.key_level_broken:
        alert.analyst_note += f" Testing key level ${alert.key_level_broken:,.0f}."
    return alert

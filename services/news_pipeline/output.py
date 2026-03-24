"""Format pipeline results for Slack / ntfy output, respecting per-source delivery."""

from __future__ import annotations

from collections import defaultdict
from typing import Any

from .config import load_scoring
from .models import MarketAlert, NewsItem, WeatherEvent

Item = NewsItem | WeatherEvent | MarketAlert


def _job_routing(profile_key: str) -> dict[str, Any]:
    return load_scoring().get("routing", {}).get(profile_key, {})


def _template(name: str) -> dict[str, Any]:
    return load_scoring().get("templates", {}).get(name, {})


def _resolve_delivery(item: Item, job: dict[str, Any]) -> dict[str, Any]:
    """Per-source delivery if present, else job-level routingProfile fallback."""
    src_del = getattr(item, "delivery", {})
    if src_del:
        delivery = dict(src_del)
    else:
        delivery = dict(_job_routing(job.get("routingProfile", "")))
    # Gold/silver only: push to #breaking-news when |change_pct| >= 5%
    if isinstance(item, MarketAlert) and item.symbol in ("XAU", "XAG") and abs(item.change_pct) >= 5.0:
        chans = list(delivery.get("slack", []))
        if "#breaking-news" not in chans:
            chans.append("#breaking-news")
        delivery = {**delivery, "slack": chans, "ntfy": True, "ntfyPriority": "high"}
    return delivery


def _resolve_template(delivery: dict[str, Any], job: dict[str, Any]) -> dict[str, Any]:
    """Template from delivery block, else from job routing, else default."""
    name = delivery.get("template") or _job_routing(job.get("routingProfile", "")).get("template", "breakingBullet")
    return _template(name)


# ── Per-item formatting ──────────────────────────────────────────────────────

def _fmt_news_item(it: NewsItem, tpl: dict[str, Any]) -> str:
    from urllib.parse import urlparse
    try:
        domain = urlparse(it.url).netloc
    except Exception:
        domain = it.url

    # Headline as plain text, link on source domain parenthetical only.
    return f"• {it.title} <{it.url}|({domain})>"


def _fmt_weather_event(ev: WeatherEvent, tpl: dict[str, Any]) -> str:
    flag = " :warning:" if ev.is_breaking else ""
    score = f"*[{ev.score}]*" if tpl.get("includeScore", True) else ""
    line = f"• {score}{flag} {ev.headline}"
    if tpl.get("includeAnalystNote") and ev.analyst_note:
        # Slack italics don't wrap cleanly across multiple lines; use code block for digests.
        if "\n" in ev.analyst_note:
            line += f"\n  ```{ev.analyst_note}```"
        else:
            line += f"\n  _{ev.analyst_note}_"
    return line


def _fmt_market_alert(al: MarketAlert, tpl: dict[str, Any]) -> str:
    direction = ":chart_with_upwards_trend:" if al.change_pct > 0 else ":chart_with_downwards_trend:"
    score = f"*[{al.score}]* " if tpl.get("includeScore", True) else ""
    line = f"• {score}{direction} {al.label}: ${al.price:,.2f} ({al.change_pct:+.1f}%)"
    if tpl.get("includeAnalystNote") and al.analyst_note:
        line += f"\n  _{al.analyst_note}_"
    return line


def _fmt_item(item: Item, tpl: dict[str, Any]) -> str:
    if isinstance(item, NewsItem):
        return _fmt_news_item(item, tpl)
    if isinstance(item, WeatherEvent):
        return _fmt_weather_event(item, tpl)
    return _fmt_market_alert(item, tpl)


# ── Group items by delivery target ──────────────────────────────────────────

def _channel_key(delivery: dict[str, Any]) -> str:
    """Hashable key for grouping: sorted slack channels + ntfy flag."""
    chans = tuple(sorted(delivery.get("slack", [])))
    ntfy = delivery.get("ntfy", False)
    tpl = delivery.get("template", "")
    return f"{chans}|{ntfy}|{tpl}"


def build_output(items: list[Item], job: dict[str, Any], desk: str) -> dict[str, Any]:
    """Build structured output grouped by per-source delivery targets."""
    policy = job.get("deliveryPolicy", {})
    job_routing = _job_routing(job.get("routingProfile", ""))

    groups: dict[str, list[tuple[Item, dict[str, Any], dict[str, Any]]]] = defaultdict(list)
    for item in sorted(items, key=lambda x: -x.score):
        delivery = _resolve_delivery(item, job)
        tpl = _resolve_template(delivery, job)
        groups[_channel_key(delivery)].append((item, delivery, tpl))

    deliveries: list[dict[str, Any]] = []
    all_actions: list[dict[str, Any]] = []

    for _key, group in groups.items():
        delivery = group[0][1]
        tpl = group[0][2]
        max_items = tpl.get("maxItems", 10)
        group = group[:max_items]

        lines = [_fmt_item(it, tpl) for it, _, _ in group]
        slack_msg = "\n".join(lines)

        min_to_ntfy = policy.get("minToNtfy", 10)  # default 10, configurable per job

        ntfy_msg = ""
        breaking = [it for it, _, _ in group if it.score >= min_to_ntfy]
        if breaking:
            ntfy_msg = build_ntfy_summary(breaking, desk)

        actions = _suggest_actions(
            [it for it, _, _ in group], policy, delivery
        )
        all_actions.extend(actions)

        deliveries.append({
            "slack": delivery.get("slack", job_routing.get("slack", [])),
            "ntfy": delivery.get("ntfy", job_routing.get("ntfy", False))
            or bool(policy.get("minToNtfy", 0)),
            "ntfyPriority": delivery.get("ntfyPriority", job_routing.get("ntfyPriority", "default")),
            "template": delivery.get("template", ""),
            "slackMessage": slack_msg,
            "ntfyMessage": ntfy_msg,
            "itemCount": len(group),
            "breakingCount": len(breaking),
        })

    total_items = sum(d["itemCount"] for d in deliveries)
    total_breaking = sum(d["breakingCount"] for d in deliveries)

    return {
        "jobId": job.get("id"),
        "desk": desk,
        "itemCount": total_items,
        "breakingCount": total_breaking,
        "deliveryPolicy": policy,
        "deliveries": deliveries,
        "suggestedActions": all_actions,
    }


def _suggest_actions(items: list[Item], policy: dict, delivery: dict) -> list[dict]:
    mode = policy.get("mode", "returnOnly")
    actions: list[dict] = []
    min_to_ntfy = policy.get("minToNtfy", 10)
    breaking = [i for i in items if i.score >= min_to_ntfy]

    if mode == "autoPost" and items:
        for ch in delivery.get("slack", []):
            actions.append({"action": "slackPost", "channel": ch})
        if delivery.get("ntfy") and breaking:
            actions.append({"action": "ntfySend", "priority": delivery.get("ntfyPriority", "high")})
    elif mode == "previewOnly":
        actions.append({"action": "queueForReview"})

    return actions


def build_ntfy_summary(items: list[Item], desk: str) -> str:
    """Simple fallback summary text for ntfy notifications."""
    count = len(items)
    top_story = items[0].title[:80] if items and isinstance(items[0], NewsItem) else "no stories"
    return f"{top_story} — {count} stories on {desk}"

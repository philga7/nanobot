"""Message templates for Slack block kit and ntfy notifications."""

from __future__ import annotations

from typing import Any

from nanobot.news.config import NTFY_TOPIC, NTFY_URL


def slack_headline(title: str, score: float, is_breaking: bool) -> str:
    prefix = ":rotating_light: *BREAKING* — " if is_breaking else ""
    return f"{prefix}[{score}] {title}"


def ntfy_headline(title: str, score: float) -> str:
    return f"BREAKING [{score}] — {title}"


def build_slack_message(
    items: list[dict[str, Any]],
    job_id: str,
    desk: str,
    channel: str,
) -> str:
    if not items:
        return ""

    header = f"*{desk}* — {len(items)} story(ies)\n"
    lines = [header]

    for item in items:
        title = item.get("title", "")
        url = item.get("url", "")
        score = item.get("score", 0)
        is_breaking = item.get("is_breaking", False)
        osint_tags = item.get("osint_tags", [])
        analyst_note = item.get("analyst_note", "")

        tags_str = f" [{', '.join(osint_tags[:3])}]" if osint_tags else ""
        headline = slack_headline(title, score, is_breaking)
        line = f"• <{url}|{headline}>{tags_str}"
        if analyst_note:
            line += f"\n  _{analyst_note}_"
        lines.append(line)

    return "\n".join(lines)


def build_ntfy_message(
    items: list[dict[str, Any]],
    desk: str,
) -> str:
    if not items:
        return ""

    lines = [f"BREAKING — {desk}"]
    for item in items[:5]:
        title = item.get("title", "")[:80]
        score = item.get("score", 0)
        lines.append(f"[{score}] {title}")

    return "\n".join(lines)


def delivery_targets(
    score: float,
    channel: str = "#breaking-news",
) -> dict[str, Any]:
    return {
        "slack_channel": channel,
        "slack_message": None,
        "ntfy": score >= 10,
        "ntfy_topic": NTFY_TOPIC,
        "ntfy_url": NTFY_URL,
    }

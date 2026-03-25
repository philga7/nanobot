"""News pipeline wrapper — reuses services/news_pipeline/, adds LLM enrichment and delivery."""

from __future__ import annotations

import asyncio
import sys
from typing import Any

import httpx

from nanobot.news import templates
from nanobot.news.agent import extract_entities, summarize_headlines
from nanobot.news.config import (
    ENRICHMENT_THRESHOLD,
    NTFY_THRESHOLD,
    NTFY_TOKEN,
    NTFY_TOPIC,
    NTFY_URL,
    SLACK_CHANNEL,
)


def _get_np_config():
    from services.news_pipeline import config as np_config
    return np_config


def _get_run_news_job():
    from services.news_pipeline.pipeline import run_news_job
    return run_news_job


def run_scheduled_news_job(dry_run: bool = False) -> dict[str, Any]:
    np_config = _get_np_config()
    run_news_job = _get_run_news_job()
    jobs = np_config.load_news_jobs()
    if not jobs:
        print("[news] No news jobs configured", file=sys.stderr)
        return {"jobs": [], "total_items": 0, "total_delivered": 0}

    all_results: list[dict[str, Any]] = asyncio.run(_run_all_jobs(jobs, run_news_job, dry_run))

    enriched = _enrich_results(all_results)

    if not dry_run:
        _deliver_results(enriched, np_config)
    else:
        for r in enriched:
            _print_result(r)

    total_items = sum(r.get("itemCount", 0) for r in all_results)
    total_delivered = sum(
        sum(d.get("itemCount", 0) for d in r.get("deliveries", []))
        for r in enriched
    )
    return {"jobs": enriched, "total_items": total_items, "total_delivered": total_delivered}


async def _run_all_jobs(jobs: list[dict[str, Any]], run_news_job: Any, dry_run: bool) -> list[dict[str, Any]]:
    results = []
    for job in jobs:
        result = await run_news_job(job, dry_run=dry_run)
        results.append(result)
    return results


def _enrich_results(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    for result in results:
        for delivery in result.get("deliveries", []):
            items = delivery.get("items", [])
            enriched_items = []
            for item in items:
                if item.get("score", 0) >= ENRICHMENT_THRESHOLD:
                    item = extract_entities(item)
                enriched_items.append(item)
            delivery["items"] = enriched_items
    return results


def _deliver_results(results: list[dict[str, Any]], np_config: Any) -> None:
    base_dir = np_config.base_dir()
    slack_token = (
        base_dir.parent.parent.joinpath("wrenvps/.slack_bot_token").expanduser().read_text().strip()
        if base_dir.parent.parent.joinpath("wrenvps/.slack_bot_token").expanduser().exists()
        else None
    )

    for result in results:
        desk = result.get("desk", "")
        for delivery in result.get("deliveries", []):
            items = delivery.get("items", [])
            if not items:
                continue

            slack_msg = templates.build_slack_message(items, result.get("jobId", ""), desk, SLACK_CHANNEL)
            ntfy_items = [i for i in items if i.get("score", 0) >= NTFY_THRESHOLD]
            ntfy_msg = summarize_headlines(ntfy_items)

            if slack_msg:
                _post_slack(slack_msg, SLACK_CHANNEL, slack_token)

            if ntfy_msg:
                _push_ntfy(ntfy_msg, desk)


def _post_slack(message: str, channel: str, token: str | None) -> None:
    if not token:
        print(f"[news] No Slack token — would post to {channel}", file=sys.stderr)
        return
    if not channel.startswith("#"):
        channel = f"#{channel}"
    try:
        resp = httpx.post(
            "https://slack.com/api/chat.postMessage",
            headers={"Authorization": f"Bearer {token}"},
            json={"channel": channel, "text": message, "unfurl_links": False},
            timeout=15,
        )
        data = resp.json()
        if data.get("ok"):
            print(f"[news] Slack → {channel}", file=sys.stderr)
        else:
            print(f"[news] Slack error: {data.get('error')}", file=sys.stderr)
    except httpx.HTTPError as e:
        print(f"[news] Slack HTTP error: {e}", file=sys.stderr)


def _push_ntfy(message: str, desk: str) -> None:
    if not NTFY_URL:
        print(f"[news] No NTFY_URL — would push to {NTFY_TOPIC}", file=sys.stderr)
        return
    url = f"{NTFY_URL.rstrip('/')}/{NTFY_TOPIC}"
    headers: dict[str, str] = {"Priority": "high", "Title": f"Breaking - {desk}"}
    if NTFY_TOKEN:
        headers["Authorization"] = f"Bearer {NTFY_TOKEN}"
    try:
        resp = httpx.post(url, content=message.encode(), headers=headers, timeout=10)
        if resp.status_code in (200, 202):
            print(f"[news] ntfy → {NTFY_TOPIC}", file=sys.stderr)
        else:
            print(f"[news] ntfy error: {resp.status_code}", file=sys.stderr)
    except httpx.HTTPError as e:
        print(f"[news] ntfy HTTP error: {e}", file=sys.stderr)


def _print_result(result: dict[str, Any]) -> None:
    print(f"\n=== {result.get('desk', 'news')} ===", file=sys.stderr)
    for delivery in result.get("deliveries", []):
        for item in delivery.get("items", []):
            score = item.get("score", 0)
            title = item.get("title", "")
            tags = item.get("osint_tags", [])
            note = item.get("analyst_note", "")
            print(f"  [{score}] {title}", file=sys.stderr)
            if tags:
                print(f"         tags: {', '.join(tags[:3])}", file=sys.stderr)
            if note:
                print(f"         {note}", file=sys.stderr)

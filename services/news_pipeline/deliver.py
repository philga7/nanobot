"""Deliver pipeline output to Slack and ntfy."""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from typing import Any

import httpx

from .config import base_dir

SLACK_BOT_TOKEN = os.environ.get("SLACK_BOT_TOKEN", os.environ.get("NANOBOT_CHANNELS__SLACK__BOT_TOKEN", ""))
NTFY_URL = os.environ.get("NTFY_URL", "")
NTFY_TOKEN = os.environ.get("NTFY_TOKEN", "")
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "news-pipeline")


def post_slack(channel: str, text: str) -> bool:
    """Post a message to a Slack channel. Returns True on success."""
    if not SLACK_BOT_TOKEN:
        print(f"  [SKIP] No SLACK_BOT_TOKEN — would post to {channel}", file=sys.stderr)
        return False

    if not channel.startswith("#"):
        channel = f"#{channel}"

    try:
        resp = httpx.post(
            "https://slack.com/api/chat.postMessage",
            headers={"Authorization": f"Bearer {SLACK_BOT_TOKEN}"},
            json={"channel": channel, "text": text, "unfurl_links": False},
            timeout=15,
        )
        data = resp.json()
        if data.get("ok"):
            print(f"  [OK] Slack → {channel}", file=sys.stderr)
            return True
        print(f"  [FAIL] Slack → {channel}: {data.get('error', 'unknown')}", file=sys.stderr)
        return False
    except httpx.HTTPError as e:
        print(f"  [ERR] Slack → {channel}: {e}", file=sys.stderr)
        return False


def push_ntfy(message: str, priority: str = "high", title: str = "News Pipeline") -> bool:
    """Push a notification via ntfy. Returns True on success."""
    if not NTFY_URL:
        print(f"  [SKIP] No NTFY_URL — would push to ntfy", file=sys.stderr)
        return False

    url = f"{NTFY_URL.rstrip('/')}/{NTFY_TOPIC}"
    headers: dict[str, str] = {"Priority": priority, "Title": title}
    if NTFY_TOKEN:
        headers["Authorization"] = f"Bearer {NTFY_TOKEN}"

    try:
        resp = httpx.post(url, content=message.encode(), headers=headers, timeout=10)
        if resp.status_code in (200, 202):
            print(f"  [OK] ntfy → {NTFY_TOPIC} (priority={priority})", file=sys.stderr)
            return True
        print(f"  [FAIL] ntfy: {resp.status_code} {resp.text[:100]}", file=sys.stderr)
        return False
    except httpx.HTTPError as e:
        print(f"  [ERR] ntfy: {e}", file=sys.stderr)
        return False


def deliver_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    """Deliver all pipeline results per their delivery groups. Returns a journal summary."""
    journal = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "jobs": [],
        "totalSlackPosts": 0,
        "totalNtfyPushes": 0,
    }

    for result in results:
        job_id = result.get("jobId", "unknown")
        desk = result.get("desk", "")
        policy = result.get("deliveryPolicy", {})
        mode = policy.get("mode", "returnOnly")
        deliveries = result.get("deliveries", [])

        job_entry: dict[str, Any] = {
            "jobId": job_id,
            "desk": desk,
            "mode": mode,
            "itemCount": result.get("itemCount", 0),
            "breakingCount": result.get("breakingCount", 0),
            "slackPosts": 0,
            "ntfyPushes": 0,
        }

        if mode == "returnOnly":
            print(f"[{job_id}] returnOnly — {result.get('itemCount', 0)} items (no delivery)", file=sys.stderr)
            journal["jobs"].append(job_entry)
            continue

        if not deliveries:
            print(f"[{job_id}] no items to deliver", file=sys.stderr)
            journal["jobs"].append(job_entry)
            continue

        print(f"[{job_id}] delivering {result.get('itemCount', 0)} items...", file=sys.stderr)

        for d in deliveries:
            slack_msg = d.get("slackMessage", "")
            ntfy_msg = d.get("ntfyMessage", "")
            channels = d.get("slack", [])
            ntfy_enabled = d.get("ntfy", False)
            ntfy_priority = d.get("ntfyPriority", "high")

            if mode == "autoPost" and slack_msg:
                for ch in channels:
                    if post_slack(ch, slack_msg):
                        job_entry["slackPosts"] += 1
                        journal["totalSlackPosts"] += 1

            if mode == "autoPost" and ntfy_enabled and ntfy_msg:
                if push_ntfy(ntfy_msg, priority=ntfy_priority, title=f"Breaking - {desk}"):
                    job_entry["ntfyPushes"] += 1
                    journal["totalNtfyPushes"] += 1

            if mode == "previewOnly" and slack_msg:
                for ch in channels:
                    if post_slack(ch, slack_msg):
                        job_entry["slackPosts"] += 1
                        journal["totalSlackPosts"] += 1

        journal["jobs"].append(job_entry)

    _write_journal(journal)
    return journal


def _write_journal(journal: dict[str, Any]) -> None:
    """Append a delivery journal entry to the history directory."""
    journal_file = base_dir() / "history" / "delivery_journal.jsonl"
    journal_file.parent.mkdir(parents=True, exist_ok=True)
    with open(journal_file, "a") as f:
        f.write(json.dumps(journal) + "\n")
    print(f"\nJournal written → {journal_file}", file=sys.stderr)

#!/usr/bin/env python3
"""Install net-audit cron jobs into workspace cron store."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from nanobot.cron.service import CronService
from nanobot.cron.types import CronSchedule


def _workspace_path() -> Path:
    configured = os.getenv("NANOBOT_AGENTS__DEFAULTS__WORKSPACE", "~/.wrenvps/workspace")
    return Path(configured).expanduser()


def _skill_dir() -> str:
    return os.environ.get(
        "NET_AUDIT_CRON_SKILL_ROOT",
        "/root/projects/nanobot/nanobot/skills/net-audit",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Install net-audit cron jobs")
    parser.add_argument("--apply", action="store_true", help="Write jobs (default dry run)")
    parser.add_argument("--replace", action="store_true", help="Replace existing net-audit jobs")
    parser.add_argument("--timezone", default="UTC")
    args = parser.parse_args()

    workspace = _workspace_path()
    store_path = workspace / "cron" / "jobs.json"
    skill = _skill_dir().rstrip("/")

    health_msg = (
        "Run net-audit alert check. "
        f"Execute: cd {skill} && bash scripts/alert.sh. "
        "Parse the JSON output. If alert key is non-null, send via mcp_ntfy_ntfy_me "
        "using PLAIN TEXT title only (no emoji, no special characters). "
        "Do NOT spawn subagents."
    )
    daily_msg = (
        "Run net-audit daily report. "
        f"Execute: cd {skill} && bash scripts/check.sh. "
        "Read the full JSON output and format a graded report card (A–F per category) "
        "based on the rubric in SKILL.md. Send the formatted report via mcp_ntfy_ntfy_me "
        "with PLAIN TEXT title only. Do NOT spawn subagents."
    )

    planned = [
        ("net-audit-health", "*/15 * * * *", health_msg),
        ("net-audit-daily", "0 12 * * *", daily_msg),
    ]

    print(f"Workspace: {workspace}")
    print(f"Cron store: {store_path}")
    print(f"Net-audit skill dir: {skill}")
    for name, expr, _ in planned:
        print(f"- {name}: {expr} ({args.timezone})")

    if not args.apply:
        print("Dry run only. Re-run with --apply to install jobs.")
        return 0

    cron = CronService(store_path)
    if args.replace:
        targets = {name for name, _, _ in planned}
        for job in cron.list_jobs(include_disabled=True):
            if job.name in targets:
                cron.remove_job(job.id)
                print(f"Removed job: {job.name} ({job.id})")

    existing_names = {j.name for j in cron.list_jobs(include_disabled=True)}
    for name, expr, message in planned:
        if name in existing_names and not args.replace:
            print(f"Skip existing job: {name}")
            continue
        cron.add_job(
            name=name,
            schedule=CronSchedule(kind="cron", expr=expr, tz=args.timezone),
            message=message,
            deliver=False,
            payload_kind="agent_turn",
        )
        print(f"Added job: {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

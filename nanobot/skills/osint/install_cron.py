#!/usr/bin/env python3
"""Install OSINT briefing cron jobs into workspace cron store."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from nanobot.cron.service import CronService
from nanobot.cron.types import CronSchedule


def _workspace_path() -> Path:
    configured = os.getenv("NANOBOT_AGENTS__DEFAULTS__WORKSPACE", "~/.wrenvps/workspace")
    return Path(configured).expanduser()


def main() -> int:
    parser = argparse.ArgumentParser(description="Install OSINT briefing cron jobs")
    parser.add_argument("--apply", action="store_true", help="Write jobs (default: dry run)")
    parser.add_argument("--timezone", default="America/New_York")
    parser.add_argument(
        "--morning-cron",
        default=os.getenv("OSINT_BRIEFING_CRON_MORNING", "0 7 * * *"),
    )
    parser.add_argument(
        "--evening-cron",
        default=os.getenv("OSINT_BRIEFING_CRON_EVENING", "0 18 * * *"),
    )
    args = parser.parse_args()

    workspace = _workspace_path()
    store_path = workspace / "cron" / "jobs.json"
    delivery_cmd = "bash nanobot/skills/osint/deliver.sh"

    planned = [
        ("osint-intel-signals-morning", args.morning_cron),
        ("osint-intel-signals-evening", args.evening_cron),
    ]

    print(f"Workspace: {workspace}")
    print(f"Cron store: {store_path}")
    for name, expr in planned:
        print(f"- {name}: {expr} ({args.timezone}) -> {delivery_cmd}")

    if not args.apply:
        print("Dry run only. Re-run with --apply to install jobs.")
        return 0

    cron = CronService(store_path)
    existing = {job.name for job in cron.list_jobs(include_disabled=True)}

    for name, expr in planned:
        if name in existing:
            print(f"Skip existing job: {name}")
            continue
        cron.add_job(
            name=name,
            schedule=CronSchedule(kind="cron", expr=expr, tz=args.timezone),
            message=delivery_cmd,
            payload_kind="shell_exec",
        )
        print(f"Added job: {name}")

    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

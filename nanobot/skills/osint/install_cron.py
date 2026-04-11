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
    parser = argparse.ArgumentParser(description="Install OSINT briefing cron jobs (per-desk)")
    parser.add_argument("--apply", action="store_true", help="Write jobs (default: dry run)")
    parser.add_argument("--timezone", default="America/New_York")
    parser.add_argument(
        "--intel-cron",
        default=os.getenv("OSINT_BRIEFING_CRON_INTEL", "0 7,18 * * *"),
        help="Cron expr for intel desk (default: 07:00 and 18:00 ET daily)",
    )
    parser.add_argument(
        "--investing-cron",
        default=os.getenv("OSINT_BRIEFING_CRON_INVESTING", "0 7 * * 1-5"),
        help="Cron expr for investing desk (default: 07:00 ET weekdays)",
    )
    parser.add_argument(
        "--weather-cron",
        default=os.getenv("OSINT_BRIEFING_CRON_WEATHER", "0 6,16 * * *"),
        help="Cron expr for weather desk (default: 06:00 and 16:00 ET daily)",
    )
    args = parser.parse_args()

    workspace = _workspace_path()
    store_path = workspace / "cron" / "jobs.json"
    base_cmd = "bash nanobot/skills/osint/deliver.sh"

    planned = [
        ("osint-intel", args.intel_cron, f"{base_cmd} --desk intel"),
        ("osint-investing", args.investing_cron, f"{base_cmd} --desk investing"),
        ("osint-weather", args.weather_cron, f"{base_cmd} --desk weather"),
    ]

    print(f"Workspace: {workspace}")
    print(f"Cron store: {store_path}")
    for name, expr, cmd in planned:
        print(f"- {name}: {expr} ({args.timezone}) -> {cmd}")

    if not args.apply:
        print("Dry run only. Re-run with --apply to install jobs.")
        return 0

    cron = CronService(store_path)
    existing = {job.name for job in cron.list_jobs(include_disabled=True)}

    for name, expr, cmd in planned:
        if name in existing:
            print(f"Skip existing job: {name}")
            continue
        cron.add_job(
            name=name,
            schedule=CronSchedule(kind="cron", expr=expr, tz=args.timezone),
            message=cmd,
            payload_kind="shell_exec",
        )
        print(f"Added job: {name}")

    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

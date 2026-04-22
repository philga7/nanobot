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


def _skill_dir() -> str:
    return os.environ.get(
        "OSINT_CRON_SKILL_ROOT",
        "/root/projects/nanobot/nanobot/skills/osint",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Install OSINT briefing cron jobs (per-desk)")
    parser.add_argument("--apply", action="store_true", help="Write jobs (default: dry run)")
    parser.add_argument(
        "--replace",
        action="store_true",
        help="Remove existing osint-* desk jobs, then add",
    )
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
        "--work-cron",
        default=os.getenv("OSINT_BRIEFING_CRON_WORK", "0 7 * * 1-5"),
        help="Cron expr for work desk (default: 07:00 ET weekdays)",
    )
    parser.add_argument(
        "--weather-cron",
        default=os.getenv("OSINT_BRIEFING_CRON_WEATHER", "0 6,16 * * *"),
        help="Cron expr for weather desk (default: 06:00 and 16:00 ET daily)",
    )
    parser.add_argument(
        "--live-feed-cron",
        default=os.getenv("OSINT_BRIEFING_CRON_LIVE_FEED", "*/30 * * * *"),
        help="Cron expr for live-feed desk (default: every 30 minutes)",
    )
    args = parser.parse_args()

    workspace = _workspace_path()
    store_path = workspace / "cron" / "jobs.json"
    skill = _skill_dir().rstrip("/")

    intel_msg = (
        "Run the OSINT intel desk brief. "
        f"Execute: cd {skill} && bash deliver.sh --desk intel --force "
        "--json /tmp/osint_brief_intel.json. "
        "Then read the JSON file at /tmp/osint_brief_intel.json and synthesize an "
        "analyst-style intelligence brief. Post the brief to Slack #intel-signals "
        "(C0AGWCQ1ZDE). Use the brief format from the OSINT skill docs — lead with "
        "priority topics, provide context, include links, be concise. "
        "Do NOT just list raw data points."
    )
    investing_msg = (
        "Run the OSINT investing desk brief. "
        f"Execute: cd {skill} && bash deliver.sh --desk investing --force "
        "--json /tmp/osint_brief_investing.json. "
        "Then read the JSON file at /tmp/osint_brief_investing.json and synthesize a "
        "market-focused brief. Post the brief to Slack #investing (C0AG5NSKVCL). "
        "Use the brief format from the OSINT skill docs — focus on market moves, "
        "rates, and economic data. Highlight any precious metals moves >= 5%."
    )
    weather_msg = (
        "Run the OSINT weather desk brief. "
        f"Execute: cd {skill} && bash deliver.sh --desk weather --force "
        "--json /tmp/osint_brief_weather.json. "
        "Then read the JSON file at /tmp/osint_brief_weather.json.\n\n"
        "The shell script outputs a weather brief template with placeholders. You must fill in ALL placeholders before posting:\n\n"
        "1. **ALERTS:** Check the NOAA alerts in the JSON. Report local alerts for Jackson, Lumpkin, and Bulloch counties first. "
        "If none, write: \"None active for our area. No watches, warnings, or advisories for Jackson, Lumpkin, or Bulloch counties. "
        "Clear sailing.\" Then mention any national weather systems (high wind, flood, severe storms) that could eventually track toward the Southeast.\n\n"
        "2. **Current Conditions:** One line per locality with current temp and condition.\n\n"
        "3. **Locality sections:** For each city (Jefferson, Dahlonega, Statesboro), write a current conditions line "
        "(temp, high/low, wind, humidity, UV) and a 2-3 sentence narrative forecast covering tonight through the next notable change.\n\n"
        "4. **Model Agreement:** Read the forecast model data (ECMWF, GFS, NAM) from the JSON. Write a narrative assessment "
        "starting with the agreement level (Very Strong / Strong / Moderate / Weak). Summarize what models agree on and where they diverge. "
        "Use sub-bullets for Temps, Wind, and other factors. Be conversational — not a data dump.\n\n"
        "5. **Key Notes:** 3-5 bullet points on notable trends, changes, or things to watch. Conversational tone.\n\n"
        "Keep the PDB structure intact: bold headers, no emoji, no bullet points in locality narratives. "
        "Do NOT include Source Health, Data Notes, or Elevated Watch sections.\n\n"
        "Post the completed brief to Slack #weather using the message tool with channel=\"slack\" and chat_id=\"C0AGWC921TJ\".\n\n"
        "IMPORTANT: Do NOT use subagents. Do NOT use curl for Slack. Use the message tool directly to post to Slack."
    )
    work_msg = (
        "Run the OSINT work desk brief. Execute: cd /root/projects/nanobot/nanobot/skills/osint && bash deliver.sh --desk work --force --json /tmp/osint_brief_work.json. Then read the JSON file at /tmp/osint_brief_work.json.\n\n"
        "The shell script outputs a work intelligence template with placeholders. You must fill in ALL placeholders before posting:\n\n"
        "1. **Bottom Line:** 1-2 sentence summary of the biggest federal contracting developments.\n\n"
        "2. **Competitor Moves:** News about Palantir, Bison Computing, and other SHIELD IDIQ holders. New contracts, press releases, hiring moves, strategy shifts. Use → Source: Headline format for links.\n\n"
        "3. **Vehicle & Program Updates:** SHIELD IDIQ, JWCC, GSA FAST, CDAO, Maven developments. New RFPs, ceiling mods, on-ramps. Use → Source: Headline format.\n\n"
        "4. **DoD/MDA Policy:** Budget changes, acquisition policy shifts, AI/defense tech priorities. Use → Source: Headline format.\n\n"
        "5. **Industry Trends:** Defense tech consolidation, small business set-aside changes, cybersecurity requirements. Use → Source: Headline format.\n\n"
        "6. **Contract Actions:** Check the fed-contracts data in the JSON. Highlight 2-3 notable awards — large amounts, new competitors, strategic significance. NOT a full dump. Format as: • Recipient — $Amount Description (Date)\n\n"
        "7. **Elevated Watch:** Topics to monitor — upcoming RFPs, expiring contracts, budget markups.\n\n"
        "Keep the PDB structure intact: bold headers, → links, no emoji, no bullet points in narratives. Do NOT include Source Health or Data Notes.\n\n"
        "Post the completed brief to Slack #work using the message tool with channel=\"slack\" and chat_id=\"C0AG24C1GFL\".\n\n"
        "IMPORTANT: Do NOT use subagents. Do NOT use curl for Slack. Use the message tool directly to post to Slack."
    )
    live_feed_msg = (
        "Run the live-feed desk: execute "
        f"`cd {skill} && bash deliver.sh --live-feed --json /tmp/osint_live_feed.json`, "
        "read the output, post new items to #live-feed (C0ALXXXXXXX), "
        "cross-post scored items to #breaking-news (C0AFVM42G4B), and send ntfy "
        "for HIGH/BREAKING items during waking hours (7 AM–11 PM ET). "
        "Update news_history.json with all new items."
    )

    planned = [
        ("osint-intel", args.intel_cron, intel_msg),
        ("osint-investing", args.investing_cron, investing_msg),
        ("osint-work", args.work_cron, work_msg),
        ("osint-weather", args.weather_cron, weather_msg),
        ("osint-live-feed", args.live_feed_cron, live_feed_msg),
    ]

    print(f"Workspace: {workspace}")
    print(f"Cron store: {store_path}")
    print(f"OSINT skill dir (in job messages): {skill}")
    for name, expr, msg in planned:
        print(f"- {name}: {expr} ({args.timezone})")
        print(f"  message ({len(msg)} chars): {msg[:120]}...")

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

    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

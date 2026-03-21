"""Main pipeline runner: load jobs, fetch, score, dedupe, format."""

from __future__ import annotations

import json
import sys
from datetime import datetime
from typing import Any

from . import config, history
from .models import MarketAlert, NewsItem, WeatherEvent
from .osint import enrich_market, enrich_news, enrich_weather
from .output import build_output
from .scoring import is_ignored, score_market_alert, score_news_item, score_weather_event
from .sources import (
    fetch_gold_api,
    fetch_news_sources,
    fetch_nws_alerts,
    fetch_nws_weekly_forecast,
    fetch_searxng_commentary_sources,
)


def run_news_job(job: dict[str, Any], dry_run: bool = False) -> dict[str, Any]:
    items = fetch_news_sources(job)
    scored: list[NewsItem] = []
    profile = job.get("scoringProfile", "breakingNews")
    osint_profile = job.get("osintProfile", "dossier")
    min_score = config.load_scoring().get("profiles", {}).get(profile, {}).get("minToSurface", 4)

    for item in items:
        if is_ignored(f"{item.title} {item.snippet} {' '.join(item.categories)}"):
            continue
        item = score_news_item(item, job)
        if item.score < min_score:
            continue
        if history.seen("news", item.dedup_key):
            continue
        item = enrich_news(item, osint_profile)
        scored.append(item)
        if not dry_run:
            history.record("news", item.dedup_key, {"title": item.title, "score": item.score})

    max_items = job.get("deliveryPolicy", {}).get("maxItemsPerRun", 10)
    scored.sort(key=lambda x: -x.score)
    scored = scored[:max_items]
    return build_output(scored, job, "news")


def run_weather_job(job: dict[str, Any], dry_run: bool = False) -> dict[str, Any]:
    """Weather dispatcher: severe monitor vs weekly outlook."""
    scoring_profile = job.get("scoringProfile", "severeWeather")
    if scoring_profile == "weeklyWeather":
        return run_weekly_outlook_job(job, dry_run=dry_run)
    return run_severe_weather_monitor_job(job, dry_run=dry_run)


def run_severe_weather_monitor_job(job: dict[str, Any], dry_run: bool = False) -> dict[str, Any]:
    """Active NWS alerts + optional SearXNG meteorologist commentary items."""
    events = fetch_nws_alerts(job)
    scored: list[WeatherEvent] = []

    profile = job.get("scoringProfile", "severeWeather")
    osint_profile = job.get("osintProfile", "shortContext")
    min_score = config.load_scoring().get("profiles", {}).get(profile, {}).get("minToSurface", 3)

    for ev in events:
        if is_ignored(f"{ev.event_type} {ev.headline}"):
            continue
        ev = score_weather_event(ev, job)
        if ev.score < min_score:
            continue
        if history.seen("weather", ev.dedup_key):
            continue
        ev = enrich_weather(ev, osint_profile)
        scored.append(ev)
        if not dry_run:
            history.record("weather", ev.dedup_key, {"headline": ev.headline, "score": ev.score})

    # Commentary: use job.commentators (SearXNG sources) and create low-priority context items.
    for src in job.get("commentators", []):
        if src.get("kind") != "searxngQuery":
            continue
        hits = fetch_searxng_commentary_sources([src])
        if not hits:
            continue
        hit = hits[0]
        if is_ignored(f"{hit.title} {hit.snippet}"):
            continue

        ev = WeatherEvent(
            event_type="Meteorologist commentary",
            location="Georgia",
            headline=(hit.title[:200] if hit.title else "Meteorologist commentary"),
            description=hit.snippet[:500],
            severity="",
            onset="",
            expires="",
            nws_id=f"commentary:{src.get('query','')}:{hit.url}",
            raw=hit.raw,
            delivery=src.get("delivery", {}),
        )
        ev.score = 3.5
        ev.is_breaking = False
        ev.analyst_note = hit.snippet[:900]

        if not history.seen("weather", ev.dedup_key):
            scored.append(ev)
            if not dry_run:
                history.record("weather", ev.dedup_key, {"headline": ev.headline, "score": ev.score})

    # Model trends: also include a compact model context (SearXNG) so the desk reflects GFS/ECMWF/ICON/UKMET.
    model_added = False
    for src in job.get("modelQueries", []):
        if src.get("kind") != "searxngQuery":
            continue
        hits = fetch_searxng_commentary_sources([src])
        if not hits:
            continue
        hit = hits[0]
        if is_ignored(f"{hit.title} {hit.snippet}"):
            continue

        ev = WeatherEvent(
            event_type="Model trends",
            location="Georgia",
            headline=(hit.title[:200] if hit.title else "Model trends"),
            description=hit.snippet[:500],
            severity="",
            onset="",
            expires="",
            nws_id=f"model:{src.get('query','')}:{hit.url}",
            raw=hit.raw,
            delivery=src.get("delivery", {}),
        )
        ev.score = 2.5
        ev.is_breaking = False
        ev.analyst_note = hit.snippet[:900]

        if not history.seen("weather", ev.dedup_key):
            scored.append(ev)
            if not dry_run:
                history.record("weather", ev.dedup_key, {"headline": ev.headline, "score": ev.score})
            model_added = True

    if job.get("modelQueries") and not model_added:
        models = job.get("models", [])
        ev = WeatherEvent(
            event_type="Model trends",
            location="Georgia",
            headline="Model trends (SearXNG unavailable)",
            description="",
            severity="",
            onset="",
            expires="",
            nws_id=f"model:placeholder:{job.get('id','severe-weather-monitor')}",
            raw={},
            delivery=job.get("delivery", {}),
        )
        ev.score = 2.0
        ev.is_breaking = False
        ev.analyst_note = f"Models configured: {', '.join(models)}."
        scored.append(ev)

    max_items = job.get("deliveryPolicy", {}).get("maxItemsPerRun", 5)
    scored.sort(key=lambda x: -x.score)
    return build_output(scored[:max_items], job, "weather")


def run_weekly_outlook_job(job: dict[str, Any], dry_run: bool = False) -> dict[str, Any]:
    """Weekly 7-day forecast summary for all configured locations + model trend commentary."""
    week = datetime.now().isocalendar().week
    year = datetime.now().isocalendar().year
    weekly_key = f"weekly:{job.get('id','weekly-outlook')}:{year}-W{week}"

    if history.seen("weather", weekly_key):
        return build_output([], job, "weather")

    forecast = fetch_nws_weekly_forecast(job)  # location -> list[periods]

    model_sources = job.get("modelQueries", [])
    commentator_sources = job.get("commentators", [])
    searx_sources = []
    searx_sources.extend(model_sources)
    searx_sources.extend(commentator_sources)

    searx_hits = fetch_searxng_commentary_sources(searx_sources) if searx_sources else []

    # Compose a compact analyst digest.
    lines: list[str] = []
    lines.append("7-day forecast (NWS):")
    for loc in job.get("locations", []):
        loc_name = loc.get("name", "")
        lines.append(f"\n{loc_name}:")
        periods = forecast.get(loc_name, [])
        for p in periods:
            day = (p.get("startTime", "")[:10] or "").strip()
            short = p.get("shortForecast") or ""
            temp = p.get("temperature")
            temp_str = ""
            if isinstance(temp, dict):
                temp_val = temp.get("value")
                temp_unit = (temp.get("unitCode") or "").split("/")[-1] if isinstance(temp.get("unitCode"), str) else ""
                if temp_val is not None:
                    temp_str = f" {temp_val}{temp_unit}"
            elif isinstance(temp, (int, float)):
                temp_str = f" {temp}"
            lines.append(f"- {day}: {short}{temp_str}")

    if searx_hits:
        lines.append("\nModel trends / commentary (SearXNG):")
        for hit in searx_hits[:8]:
            title = (hit.title or "").strip()[:120]
            snippet = (hit.snippet or "").strip()[:240]
            if title:
                lines.append(f"- {title}: {snippet}")
    else:
        models = job.get("models", [])
        if models:
            lines.append("\nModel trends / commentary (SearXNG):")
            lines.append(f"- Models configured: {', '.join(models)}; no SearXNG results available.")

    summary = "\n".join(lines).strip()

    ev = WeatherEvent(
        event_type="Weekly Outlook",
        location="Georgia",
        headline=job.get("description", "Weekly outlook"),
        description="",
        severity="",
        onset="",
        expires="",
        nws_id=weekly_key,
        raw={},
        delivery={},
    )
    ev.score = 5.0
    ev.is_breaking = False
    ev.analyst_note = summary

    if not dry_run:
        history.record("weather", weekly_key, {"headline": ev.headline, "score": ev.score})

    max_items = job.get("deliveryPolicy", {}).get("maxItemsPerRun", 5)
    return build_output([ev][:max_items], job, "weather")


def run_markets_job(job: dict[str, Any], dry_run: bool = False) -> dict[str, Any]:
    alerts = fetch_gold_api(job)
    scored: list[MarketAlert] = []
    profile = job.get("scoringProfile", "metals")
    osint_profile = job.get("osintProfile", "shortContext")
    min_score = config.load_scoring().get("profiles", {}).get(profile, {}).get("minToSurface", 4)
    suppress_delta = job.get("alertRules", {}).get("suppressDuplicateDeltaPct", 0.5)

    for al in alerts:
        if is_ignored(al.label):
            continue
        al = score_market_alert(al, job)
        if al.score < min_score:
            continue
        prev = history.last_value("markets", al.symbol)
        if prev and abs(al.change_pct - prev.get("change_pct", 0)) < suppress_delta:
            continue
        al = enrich_market(al, osint_profile)
        scored.append(al)
        if not dry_run:
            history.record("markets", al.symbol, {"price": al.price, "change_pct": al.change_pct, "score": al.score})

    max_items = job.get("deliveryPolicy", {}).get("maxItemsPerRun", 5)
    scored.sort(key=lambda x: -x.score)
    scored = scored[:max_items]
    return build_output(scored, job, "markets")


JOB_RUNNERS = {
    "news": run_news_job,
    "weather": run_weather_job,
    "markets": run_markets_job,
}


def run_all(dry_run: bool = False) -> list[dict[str, Any]]:
    """Run all enabled jobs across all desks."""
    results: list[dict[str, Any]] = []

    for job in config.load_news_jobs():
        if job.get("enabled", True):
            results.append(run_news_job(job, dry_run))

    for job in config.load_weather_jobs():
        if job.get("enabled", True):
            results.append(run_weather_job(job, dry_run))

    for job in config.load_markets_jobs():
        if job.get("enabled", True):
            results.append(run_markets_job(job, dry_run))

    return results


def run_job(job_id: str, dry_run: bool = False) -> dict[str, Any] | None:
    """Run a single job by id."""
    all_jobs = config.load_news_jobs() + config.load_weather_jobs() + config.load_markets_jobs()
    for job in all_jobs:
        if job.get("id") == job_id:
            runner = JOB_RUNNERS.get(job.get("type", ""))
            if runner:
                return runner(job, dry_run)
    return None


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="News pipeline runner")
    parser.add_argument("--job", help="Run a specific job by id (omit for all)")
    parser.add_argument("--dry-run", action="store_true", help="Score and format but don't mutate history")
    parser.add_argument("--deliver", action="store_true", help="Post results to Slack/ntfy (end-to-end)")
    parser.add_argument("--desk", choices=["news", "weather", "markets"], help="Run all jobs for a desk")
    args = parser.parse_args()

    dry_run = args.dry_run and not args.deliver

    if args.job:
        result = run_job(args.job, dry_run=dry_run)
        results = [result] if result else []
    elif args.desk:
        loader = {"news": config.load_news_jobs, "weather": config.load_weather_jobs, "markets": config.load_markets_jobs}[args.desk]
        runner = JOB_RUNNERS[args.desk]
        results = [runner(j, dry_run) for j in loader() if j.get("enabled", True)]
    else:
        results = run_all(dry_run=dry_run)

    if args.deliver:
        from .deliver import deliver_results
        journal = deliver_results(results)
        print(json.dumps(journal, indent=2))
    else:
        print(json.dumps(results, indent=2))

    breaking = sum(r.get("breakingCount", 0) for r in results)
    total = sum(r.get("itemCount", 0) for r in results)
    print(f"\n--- {total} items, {breaking} breaking ---", file=sys.stderr)


if __name__ == "__main__":
    main()

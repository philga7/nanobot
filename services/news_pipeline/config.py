"""Load JSON configs from the news-pipeline directory."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

DEFAULT_BASE = os.path.expanduser("~/.wrenvps/news-pipeline")


def base_dir() -> Path:
    return Path(os.environ.get("NEWS_PIPELINE_DIR", DEFAULT_BASE))


def _load(name: str) -> dict[str, Any]:
    p = base_dir() / name
    if not p.exists():
        return {}
    with open(p) as f:
        return json.load(f)


def load_scoring() -> dict[str, Any]:
    return _load("scoring.json")


def load_news_jobs() -> list[dict[str, Any]]:
    return _load("jobs.news.json").get("jobs", [])


def load_weather_jobs() -> list[dict[str, Any]]:
    return _load("jobs.weather.json").get("jobs", [])


def load_markets_jobs() -> list[dict[str, Any]]:
    return _load("jobs.markets.json").get("jobs", [])


def load_topics() -> dict[str, Any]:
    return _load("topics.json")


def history_dir() -> Path:
    d = base_dir() / "history"
    d.mkdir(parents=True, exist_ok=True)
    return d

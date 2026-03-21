"""Shared data models for the news pipeline."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any


@dataclass
class NewsItem:
    title: str
    url: str
    source_kind: str
    published: str = ""
    categories: list[str] = field(default_factory=list)
    snippet: str = ""
    raw: dict[str, Any] = field(default_factory=dict)
    delivery: dict[str, Any] = field(default_factory=dict)

    # computed by scoring
    score: float = 0.0
    is_breaking: bool = False
    osint_tags: list[str] = field(default_factory=list)
    impact: dict[str, float] = field(default_factory=dict)
    analyst_note: str = ""
    dossier: str = ""

    # flags (CFP-specific)
    has_breaking_label: bool = False
    has_live_label: bool = False

    @property
    def dedup_key(self) -> str:
        from urllib.parse import urlparse
        parsed = urlparse(self.url)
        return f"{parsed.netloc}{parsed.path}".rstrip("/").lower()


@dataclass
class WeatherEvent:
    event_type: str
    location: str
    headline: str
    description: str = ""
    severity: str = ""
    onset: str = ""
    expires: str = ""
    nws_id: str = ""
    raw: dict[str, Any] = field(default_factory=dict)
    delivery: dict[str, Any] = field(default_factory=dict)

    score: float = 0.0
    is_breaking: bool = False
    osint_tags: list[str] = field(default_factory=list)
    analyst_note: str = ""

    @property
    def dedup_key(self) -> str:
        return f"{self.nws_id}:{self.location}".lower()


@dataclass
class MarketAlert:
    symbol: str
    label: str
    price: float
    change_pct: float = 0.0
    key_level_broken: float | None = None
    timestamp: float = field(default_factory=time.time)
    raw: dict[str, Any] = field(default_factory=dict)
    delivery: dict[str, Any] = field(default_factory=dict)

    score: float = 0.0
    is_breaking: bool = False
    osint_tags: list[str] = field(default_factory=list)
    analyst_note: str = ""

    @property
    def dedup_key(self) -> str:
        return f"{self.symbol}:{self.price:.2f}"

"""Dedupe / history store backed by JSON files."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .config import history_dir

# Configurable TTL: items older than this (seconds) get pruned on save
HISTORY_TTL = 7 * 86400  # 7 days


def _path(desk: str) -> Path:
    return history_dir() / f"{desk}_history.json"


def _load(desk: str) -> dict[str, Any]:
    p = _path(desk)
    if not p.exists():
        return {}
    with open(p) as f:
        return json.load(f)


def _save(desk: str, data: dict[str, Any]) -> None:
    cutoff = time.time() - HISTORY_TTL
    pruned = {k: v for k, v in data.items() if v.get("ts", 0) > cutoff}
    with open(_path(desk), "w") as f:
        json.dump(pruned, f, indent=2)


def seen(desk: str, key: str) -> bool:
    return key in _load(desk)


def record(desk: str, key: str, meta: dict[str, Any] | None = None) -> None:
    data = _load(desk)
    data[key] = {"ts": time.time(), **(meta or {})}
    _save(desk, data)


def last_value(desk: str, key: str) -> dict[str, Any] | None:
    return _load(desk).get(key)

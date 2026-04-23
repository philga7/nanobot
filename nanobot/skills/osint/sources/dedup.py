#!/usr/bin/env python3
"""Shared dedup/history helper for OSINT desks."""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

DEFAULT_HISTORY = Path.home() / ".wrenvps" / "intel" / "history" / "news_history.json"


def _title_hash(title: str) -> str:
    t = (title or "").strip().lower()
    return hashlib.sha1(t.encode("utf-8")).hexdigest()


def _brief_filter_by_manifest(brief: dict[str, Any], manifest_path: Path) -> dict[str, Any]:
    seen: set[str] = set()
    if manifest_path.exists():
        try:
            raw = json.loads(manifest_path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                for h in raw.get("hashes") or []:
                    if isinstance(h, str) and h:
                        seen.add(h)
        except Exception:
            pass

    def keep_rss(row: dict[str, Any]) -> bool:
        title = str(row.get("title") or row.get("headline") or row.get("text") or "")
        return _title_hash(title) not in seen

    def keep_tw(row: dict[str, Any]) -> bool:
        title = str(row.get("text") or row.get("content") or row.get("full_text") or "")
        return _title_hash(title) not in seen

    out = dict(brief)
    out["rss"] = [r for r in (brief.get("rss") or []) if isinstance(r, dict) and keep_rss(r)]
    out["twitter"] = [t for t in (brief.get("twitter") or []) if isinstance(t, dict) and keep_tw(t)]
    prev_meta = brief.get("meta")
    meta = dict(prev_meta) if isinstance(prev_meta, dict) else {}
    meta["brief_manifest_hits"] = (len(brief.get("rss") or []) - len(out["rss"])) + (
        len(brief.get("twitter") or []) - len(out["twitter"])
    )
    out["meta"] = meta
    return out


def _brief_save_manifest(manifest_path: Path, titles: list[str]) -> None:
    hashes = sorted({_title_hash(t) for t in titles if str(t).strip()})
    _ensure_parent(manifest_path)
    payload = {
        "hashes": hashes,
        "saved_at": _iso_z(_utc_now()),
        "count": len(hashes),
    }
    manifest_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _utc_now() -> datetime:
    return datetime.now(tz=UTC)


def _iso_z(ts: datetime) -> str:
    return ts.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    raw = ts.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(raw).astimezone(UTC)
    except ValueError:
        return None


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _load_history(path: Path) -> dict[str, dict[str, Any]]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _write_history(path: Path, data: dict[str, dict[str, Any]]) -> None:
    _ensure_parent(path)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


@dataclass
class AddPayload:
    key: str
    first_seen: str
    last_seen: str
    source: str | None
    source_type: str | None
    title: str | None
    desks: list[str]
    channels: list[str]
    score: float | None
    urgency: str | None

    @classmethod
    def from_input(cls, raw: dict[str, Any]) -> "AddPayload":
        key = str(raw.get("key") or raw.get("guid") or raw.get("tweet_id") or raw.get("url") or "").strip()
        if not key:
            raise ValueError("missing key/guid/tweet_id/url")
        now = _iso_z(_utc_now())
        pub_date = str(raw.get("firstSeen") or raw.get("first_seen") or raw.get("pub_date") or "").strip()
        first_seen = pub_date if _parse_iso(pub_date) else now
        last_seen = str(raw.get("lastSeen") or raw.get("last_seen") or now).strip()
        if not _parse_iso(last_seen):
            last_seen = now
        desks = [str(x) for x in (raw.get("desks") or []) if str(x).strip()]
        channels = [str(x) for x in (raw.get("channels") or []) if str(x).strip()]
        score_val = raw.get("score")
        score = float(score_val) if isinstance(score_val, (int, float)) else None
        return cls(
            key=key,
            first_seen=first_seen,
            last_seen=last_seen,
            source=(str(raw.get("source")).strip() or None) if raw.get("source") is not None else None,
            source_type=(
                str(raw.get("sourceType") or raw.get("source_type")).strip() or None
            ) if (raw.get("sourceType") is not None or raw.get("source_type") is not None) else None,
            title=(str(raw.get("title")).strip() or None) if raw.get("title") is not None else None,
            desks=desks,
            channels=channels,
            score=score,
            urgency=(str(raw.get("urgency")).strip() or None) if raw.get("urgency") is not None else None,
        )


def cmd_check(history: dict[str, dict[str, Any]], key: str) -> int:
    print("seen" if key in history else "new")
    return 0


def cmd_add(history: dict[str, dict[str, Any]], payload: AddPayload) -> tuple[dict[str, dict[str, Any]], int]:
    current = history.get(payload.key, {})
    merged_desks = sorted(set([*(current.get("desks") or []), *payload.desks]))
    merged_channels = sorted(set([*(current.get("channels") or []), *payload.channels]))
    first_seen = current.get("firstSeen") or payload.first_seen
    if _parse_iso(payload.first_seen) and _parse_iso(first_seen):
        first_seen_dt = min(_parse_iso(payload.first_seen), _parse_iso(first_seen))
        first_seen = _iso_z(first_seen_dt)

    updated: dict[str, Any] = {
        "firstSeen": first_seen,
        "lastSeen": payload.last_seen,
        "source": payload.source or current.get("source"),
        "sourceType": payload.source_type or current.get("sourceType"),
        "title": payload.title or current.get("title"),
        "desks": merged_desks,
        "channels": merged_channels,
        "score": payload.score if payload.score is not None else current.get("score"),
        "urgency": payload.urgency or current.get("urgency"),
    }
    history[payload.key] = {k: v for k, v in updated.items() if v is not None and v != []}
    print("updated" if current else "added")
    return history, 0


def cmd_prune(history: dict[str, dict[str, Any]], days: int) -> tuple[dict[str, dict[str, Any]], int]:
    cutoff = _utc_now() - timedelta(days=days)
    pruned: dict[str, dict[str, Any]] = {}
    removed = 0
    for key, meta in history.items():
        ts = _parse_iso(str(meta.get("lastSeen") or meta.get("firstSeen") or ""))
        if ts and ts < cutoff:
            removed += 1
            continue
        pruned[key] = meta
    print(removed)
    return pruned, 0


def cmd_export(history: dict[str, dict[str, Any]], desk: str) -> int:
    out = {k: v for k, v in history.items() if desk in (v.get("desks") or [])}
    print(json.dumps(out, indent=2, sort_keys=True))
    return 0


def cmd_since(history: dict[str, dict[str, Any]], since: str) -> int:
    since_dt = _parse_iso(since)
    if not since_dt:
        raise ValueError("--since must be an ISO-8601 timestamp")
    out = {
        k: v
        for k, v in history.items()
        if (_parse_iso(str(v.get("firstSeen") or "")) and _parse_iso(str(v.get("firstSeen") or "")) >= since_dt)
    }
    print(json.dumps(out, indent=2, sort_keys=True))
    return 0


def _parse_add_payload(add_arg: str, stdin_text: str) -> AddPayload:
    if add_arg == "-":
        raw = json.loads(stdin_text.strip() or "{}")
    else:
        add_path = Path(add_arg)
        raw = json.loads(add_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError("--add payload must be a JSON object")
    return AddPayload.from_input(raw)


def main() -> int:
    parser = argparse.ArgumentParser(description="OSINT history/dedup helper")
    parser.add_argument("--history", default=str(DEFAULT_HISTORY), help="Path to news_history.json")
    parser.add_argument("--check", help="Check key/guid/tweet id")
    parser.add_argument("--add", help="Add item from JSON file path, or '-' for stdin")
    parser.add_argument("--prune", type=int, help="Prune items older than N days")
    parser.add_argument("--export", dest="desk_export", help="Export entries seen by desk id")
    parser.add_argument("--since", help="Export entries with firstSeen >= timestamp")
    parser.add_argument(
        "--brief-filter-manifest",
        metavar="PATH",
        help="Read brief JSON from stdin; drop rss/twitter rows whose title hash was in manifest",
    )
    parser.add_argument(
        "--brief-save-manifest",
        metavar="PATH",
        help="Read JSON {\"titles\":[...]} from stdin; write headline hashes for next-brief dedup",
    )
    args = parser.parse_args()

    selected = [
        args.check,
        args.add,
        args.prune is not None,
        args.desk_export,
        args.since,
        args.brief_filter_manifest,
        args.brief_save_manifest,
    ]
    if sum(bool(x) for x in selected) != 1:
        parser.error(
            "choose exactly one operation: --check | --add | --prune | --export | --since | "
            "--brief-filter-manifest | --brief-save-manifest"
        )

    history_path = Path(args.history).expanduser()
    history = _load_history(history_path)

    if args.check:
        return cmd_check(history, args.check)

    if args.add:
        import sys

        payload = _parse_add_payload(args.add, sys.stdin.read())
        history, code = cmd_add(history, payload)
        _write_history(history_path, history)
        return code

    if args.prune is not None:
        history, code = cmd_prune(history, args.prune)
        _write_history(history_path, history)
        return code

    if args.desk_export:
        return cmd_export(history, args.desk_export)

    if args.since:
        return cmd_since(history, args.since)

    if args.brief_filter_manifest:
        import sys

        manifest = Path(args.brief_filter_manifest).expanduser()
        raw_in = json.loads(sys.stdin.read() or "{}")
        if not isinstance(raw_in, dict):
            raise SystemExit("stdin must be a JSON object (brief)")
        filtered = _brief_filter_by_manifest(raw_in, manifest)
        print(json.dumps(filtered, ensure_ascii=False))
        return 0

    if args.brief_save_manifest:
        import sys

        manifest = Path(args.brief_save_manifest).expanduser()
        raw_in = json.loads(sys.stdin.read() or "{}")
        if not isinstance(raw_in, dict):
            raise SystemExit("stdin must be a JSON object with \"titles\" array")
        titles = raw_in.get("titles") or []
        if not isinstance(titles, list):
            raise SystemExit("\"titles\" must be an array")
        _brief_save_manifest(manifest, [str(x) for x in titles])
        print(manifest)
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

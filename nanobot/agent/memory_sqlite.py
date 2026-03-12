"""Optional SQLite+FTS5 store for searchable memory recall."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from loguru import logger

from nanobot.agent.tools.base import Tool


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


class MemorySqliteStore:
    """SQLite-backed store with FTS5 full-text search over memory entries."""

    def __init__(self, db_path: Path) -> None:
        self.db_path = Path(db_path)
        self._ensure_db()

    def _ensure_db(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(self.db_path))
        try:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS memory_entries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    content TEXT NOT NULL,
                    source TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
                    content,
                    content='memory_entries',
                    content_rowid='id'
                )
                """
            )
            # Keep FTS in sync with memory_entries
            conn.execute(
                """
                CREATE TRIGGER IF NOT EXISTS memory_entries_ai AFTER INSERT ON memory_entries BEGIN
                    INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
                END
                """
            )
            conn.execute(
                """
                CREATE TRIGGER IF NOT EXISTS memory_entries_ad AFTER DELETE ON memory_entries BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content) VALUES ('delete', old.id, old.content);
                END
                """
            )
            conn.execute(
                """
                CREATE TRIGGER IF NOT EXISTS memory_entries_au AFTER UPDATE ON memory_entries BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content) VALUES ('delete', old.id, old.content);
                    INSERT INTO memory_fts(rowid, content) VALUES (new.id, new.content);
                END
                """
            )
            conn.commit()
        finally:
            conn.close()

    def insert(self, content: str, source: str = "consolidation") -> None:
        """Append a memory entry and index it for FTS."""
        if not content or not content.strip():
            return
        conn = sqlite3.connect(str(self.db_path))
        try:
            conn.execute(
                "INSERT INTO memory_entries (content, source, created_at) VALUES (?, ?, ?)",
                (content.strip(), source, _utc_now()),
            )
            conn.commit()
        except Exception as e:
            logger.warning("Memory SQLite insert failed: {}", e)
        finally:
            conn.close()

    def search(self, query: str, limit: int = 10) -> list[dict[str, Any]]:
        """Full-text search over content. Returns list of {content, source, created_at}."""
        if not query or not query.strip():
            return []
        limit = max(1, min(limit, 50))
        conn = sqlite3.connect(str(self.db_path))
        try:
            # FTS5 MATCH: quote special chars and use AND for multiple terms
            # Simple: pass query as-is; SQLite FTS5 accepts quoted phrases
            cur = conn.execute(
                """
                SELECT m.content, m.source, m.created_at
                FROM memory_fts f
                JOIN memory_entries m ON m.id = f.rowid
                WHERE memory_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """,
                (query.strip(), limit),
            )
            rows = cur.fetchall()
            return [
                {"content": r[0], "source": r[1], "created_at": r[2]}
                for r in rows
            ]
        except sqlite3.OperationalError as e:
            if "syntax error" in str(e).lower() or "malformed" in str(e).lower():
                # Fallback: LIKE search if FTS query is invalid
                term = query.strip().replace("%", "\\%").replace("_", "\\_")
                cur = conn.execute(
                    """
                    SELECT content, source, created_at
                    FROM memory_entries
                    WHERE content LIKE ?
                    ORDER BY created_at DESC
                    LIMIT ?
                    """,
                    (f"%{term}%", limit),
                )
                rows = cur.fetchall()
                return [
                    {"content": r[0], "source": r[1], "created_at": r[2]}
                    for r in rows
                ]
            logger.warning("Memory SQLite search failed: {}", e)
            return []
        finally:
            conn.close()


class SearchMemoryTool(Tool):
    """Tool that runs FTS over the SQLite memory store. Registered only when tools.memory.sqlite_enabled."""

    name = "search_memory"
    description = "Search long-term memory by keyword or phrase. Use when you need to recall past facts or events that may have been consolidated."
    parameters = {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Search query (keywords or phrase)"},
            "limit": {"type": "integer", "description": "Max results (1–50)", "minimum": 1, "maximum": 50},
        },
        "required": ["query"],
    }

    def __init__(self, store: MemorySqliteStore, max_results: int = 10) -> None:
        self._store = store
        self._max_results = max_results

    async def execute(self, query: str, limit: int | None = None, **kwargs: Any) -> str:
        n = limit if limit is not None else self._max_results
        n = max(1, min(50, n))
        results = self._store.search(query, limit=n)
        if not results:
            return f"No memory entries matched: {query}"
        lines = [f"Memory search for: {query}\n"]
        for i, r in enumerate(results, 1):
            lines.append(f"{i}. [{r.get('created_at', '')}] ({r.get('source', '')})")
            lines.append(f"   {r.get('content', '')}")
        return "\n".join(lines)

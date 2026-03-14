"""Optional Hindsight client for long-term agent memory via retain/recall."""

from __future__ import annotations

import asyncio
import os
from typing import Any

from loguru import logger


def _get_client():
    """Lazy-import to avoid load if Hindsight is not used."""
    from hindsight_client import Hindsight

    base_url = os.getenv("HINDSIGHT_API_URL", "").strip()
    if not base_url:
        return None
    return Hindsight(base_url=base_url, timeout=30.0)


async def retain_memory(
    content: str,
    bank_id: str | None = None,
    context: str = "consolidation",
    metadata: dict[str, Any] | None = None,
) -> None:
    """
    Store a memory in Hindsight (retain). Best-effort only; failures are logged, not raised.
    """
    if not content or not content.strip():
        return

    base_url = os.getenv("HINDSIGHT_API_URL", "").strip()
    if not base_url:
        return

    resolved_bank = bank_id or os.getenv("HINDSIGHT_BANK_ID", "nanobot")

    def _do_retain() -> None:
        client = _get_client()
        if client is None:
            return
        client.retain(
            bank_id=resolved_bank,
            content=content.strip(),
            context=context,
            metadata=metadata or {},
        )

    try:
        await asyncio.to_thread(_do_retain)
    except Exception:
        logger.debug("Hindsight retain skipped: {}", exc_info=True)


async def recall_memory(
    query: str,
    bank_id: str | None = None,
    max_tokens: int | None = None,
) -> list[dict[str, Any]]:
    """
    Retrieve memories from Hindsight (recall). Returns empty list on failure or if disabled.
    """
    if not query or not query.strip():
        return []

    base_url = os.getenv("HINDSIGHT_API_URL", "").strip()
    if not base_url:
        return []

    resolved_bank = bank_id or os.getenv("HINDSIGHT_BANK_ID", "nanobot")

    def _do_recall() -> list[dict[str, Any]]:
        client = _get_client()
        if client is None:
            return []
        kwargs: dict[str, Any] = {"bank_id": resolved_bank, "query": query.strip()}
        if max_tokens is not None:
            kwargs["max_tokens"] = max_tokens
        response = client.recall(**kwargs)
        if hasattr(response, "results"):
            return [{"content": getattr(r, "text", str(r)), "type": getattr(r, "type", None)} for r in response.results]
        if isinstance(response, list):
            return [r if isinstance(r, dict) else {"content": str(r)} for r in response]
        return [{"content": str(response)}] if response else []

    try:
        return await asyncio.to_thread(_do_recall)
    except Exception:
        logger.debug("Hindsight recall failed: {}", exc_info=True)
        return []

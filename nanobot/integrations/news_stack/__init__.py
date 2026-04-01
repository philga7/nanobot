"""Externalized news stack integration contracts."""

from nanobot.integrations.news_stack.api_context import (
    NEWS_STACK_DECIDE_CONTEXT_KEY,
    build_api_path_process_direct_metadata,
)
from nanobot.integrations.news_stack.contracts import (
    CrucixSignal,
    DecideAndActContext,
    DecideAndActRequest,
    DecideAndActResponse,
    IngestSignalRequest,
    MemoryPoint,
    MemorySearchHit,
    MemorySearchRequest,
    MemorySearchResponse,
    MemoryUpsertRequest,
    PlannedAction,
)

__all__ = [
    "NEWS_STACK_DECIDE_CONTEXT_KEY",
    "build_api_path_process_direct_metadata",
    "CrucixSignal",
    "IngestSignalRequest",
    "DecideAndActContext",
    "DecideAndActRequest",
    "PlannedAction",
    "DecideAndActResponse",
    "MemoryPoint",
    "MemoryUpsertRequest",
    "MemorySearchRequest",
    "MemorySearchHit",
    "MemorySearchResponse",
]

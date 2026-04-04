"""Contracts for the externalized news stack integration.

These models define the payload boundary between nanobot and:
- Crucix (signal ingestion)
- 7/24 Office (reasoning + tool orchestration)
- Qdrant-backed memory services
"""

from datetime import UTC, datetime
from typing import Any, Literal

from pydantic import BaseModel, Field

SignalTier = Literal["FLASH", "PRIORITY", "ROUTINE"]
SignalSource = Literal["crucix", "manual", "other"]
ActionType = Literal["notify_user", "store_memory", "run_tool", "create_tool", "noop"]


class CrucixSignal(BaseModel):
    """Normalized signal payload emitted by Crucix."""

    signal_id: str
    title: str
    summary: str = ""
    url: str | None = None
    tier: SignalTier
    published_at: datetime | None = None
    source: SignalSource = "crucix"
    tags: list[str] = Field(default_factory=list)
    raw: dict[str, Any] = Field(default_factory=dict)


class IngestSignalRequest(BaseModel):
    """Input contract for ingesting a signal into nanobot."""

    signal: CrucixSignal
    received_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    dry_run: bool = False


class DecideAndActContext(BaseModel):
    """Context passed from nanobot gateway to the execution layer."""

    signal: CrucixSignal | None = None
    channel: str | None = None
    chat_id: str | None = None
    recent_messages: list[str] = Field(default_factory=list)
    metadata: dict[str, Any] = Field(default_factory=dict)


class DecideAndActRequest(BaseModel):
    """Request contract for 7/24 Office reasoning and action planning."""

    context: DecideAndActContext
    dry_run: bool = False


class PlannedAction(BaseModel):
    """Action selected by the reasoning layer."""

    action_type: ActionType
    reason: str
    payload: dict[str, Any] = Field(default_factory=dict)


class DecideAndActResponse(BaseModel):
    """Response contract returned by the reasoning layer."""

    decision_id: str
    actions: list[PlannedAction] = Field(default_factory=list)
    model: str | None = None
    raw: dict[str, Any] = Field(default_factory=dict)


class MemoryPoint(BaseModel):
    """Document/embedding point for durable vector memory."""

    point_id: str
    text: str
    vector: list[float] | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class MemoryUpsertRequest(BaseModel):
    """Upsert contract for Qdrant-backed memory."""

    collection: str = "nanobot-memory"
    points: list[MemoryPoint]


class MemorySearchRequest(BaseModel):
    """Search contract for Qdrant-backed memory."""

    collection: str = "nanobot-memory"
    query: str
    limit: int = Field(default=10, ge=1, le=100)
    filter: dict[str, Any] = Field(default_factory=dict)


class MemorySearchHit(BaseModel):
    """Search result item returned by vector memory."""

    point_id: str
    score: float
    text: str
    metadata: dict[str, Any] = Field(default_factory=dict)


class MemorySearchResponse(BaseModel):
    """Search response contract for Qdrant-backed memory."""

    hits: list[MemorySearchHit] = Field(default_factory=list)

"""OpenAI-compatible API path: attach external-stack context to inbound metadata."""

from __future__ import annotations

from typing import Any

from nanobot.integrations.news_stack.contracts import DecideAndActContext

# InboundMessage.metadata key — bridges / hooks can read this alongside gateway traffic.
NEWS_STACK_DECIDE_CONTEXT_KEY = "news_stack_decide_context"


def build_api_path_process_direct_metadata(
    *,
    session_key: str,
    chat_id: str,
    user_message: str,
    http_request_id: str | None = None,
) -> dict[str, Any]:
    """Metadata for AgentLoop.process_direct from the HTTP API transport.

    Mirrors gateway semantics: same DecideAndActContext shape so 7/24 Office and
    Crucix bridges can treat ``channel=\"api\"`` as a first-class entrypoint.
    """
    meta: dict[str, Any] = {
        "session_key": session_key,
        "transport": "openai_api",
    }
    if http_request_id:
        meta["http_request_id"] = http_request_id

    ctx = DecideAndActContext(
        channel="api",
        chat_id=chat_id,
        recent_messages=[user_message] if user_message else [],
        metadata=meta,
    )
    return {NEWS_STACK_DECIDE_CONTEXT_KEY: ctx.model_dump(mode="json")}

"""Senior analyst OSINT agent — LLM entity extraction and story analysis."""

from __future__ import annotations

import json
import os
import sys
from typing import Any

from openai import OpenAI

DEFAULT_MODEL = os.environ.get("NANOBOT_NEWS_MODEL", "minimax-m2.7:cloud")


def _news_openai_client() -> OpenAI:
    """OpenAI-compatible client for news pipeline (Ollama, OpenRouter, etc.)."""
    api_key = os.environ.get("NANOBOT_NEWS_API_KEY") or os.environ.get("OPENAI_API_KEY") or "ollama"
    base_url = (
        os.environ.get("NANOBOT_NEWS_OPENAI_BASE_URL")
        or os.environ.get("NANOBOT_NEWS_API_BASE")
        or os.environ.get("OPENAI_API_BASE")
    )
    if base_url:
        return OpenAI(api_key=api_key, base_url=base_url.rstrip("/"))
    return OpenAI(api_key=api_key, base_url="http://127.0.0.1:11434/v1")


def _normalize_model_name(model: str) -> str:
    """Strip legacy LiteLLM-style provider prefixes for OpenAI-compatible servers."""
    for prefix in ("ollama/", "openai/", "openrouter/"):
        if model.startswith(prefix):
            return model[len(prefix) :]
    return model


def _chat_completion(
    *,
    model: str,
    messages: list[dict[str, str]],
    max_tokens: int,
    response_format: dict[str, str] | None = None,
) -> Any:
    client = _news_openai_client()
    m = _normalize_model_name(model)
    kwargs: dict[str, Any] = {
        "model": m,
        "messages": messages,
        "max_tokens": max_tokens,
    }
    if response_format is not None:
        kwargs["response_format"] = response_format
    return client.chat.completions.create(**kwargs)


def extract_entities(item: dict[str, Any]) -> dict[str, Any]:
    title = item.get("title", "")
    snippet = item.get("snippet", "")
    tags = item.get("osint_tags", [])
    score = item.get("score", 0)

    if not title:
        return item

    try:
        response = _chat_completion(
            model=DEFAULT_MODEL,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are a senior OSINT analyst. Extract structured intelligence from a news story. "
                        "Return ONLY valid JSON with no markdown, no explanation. "
                        "Schema: {\"people\": [], \"organizations\": [], \"locations\": [], "
                        "\"related_urls\": [], \"threat_indicators\": [], \"summary\": \"\"}"
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        f"Title: {title}\n"
                        f"Snippet: {snippet}\n"
                        f"Existing tags: {', '.join(tags)}\n"
                        f"Priority score: {score}/10\n\n"
                        "Extract entities and assess threat indicators."
                    ),
                },
            ],
            max_tokens=500,
            response_format={"type": "json_object"},
        )
        content = (response.choices[0].message.content or "").strip()
        if content.startswith("```"):
            content = content.split("```")[1]
            if content.startswith("json"):
                content = content[4:]
        result: dict[str, Any] = json.loads(content)
        item["entities"] = result
        item["analyst_note"] = _build_analyst_note(result, tags)
        return item
    except Exception as e:
        print(f"[news] LLM entity extraction failed: {e}", file=sys.stderr)
        return item


def _build_analyst_note(entities: dict[str, Any], existing_tags: list[str]) -> str:
    people = entities.get("people", [])
    orgs = entities.get("organizations", [])
    locations = entities.get("locations", [])
    threats = entities.get("threat_indicators", [])

    parts = []
    if orgs:
        parts.append(f"Orgs: {', '.join(orgs[:3])}")
    if locations:
        parts.append(f"Locs: {', '.join(locations[:3])}")
    if people:
        parts.append(f"Key figures: {', '.join(people[:2])}")
    if threats:
        parts.append(f"Threat signals: {', '.join(threats[:2])}")

    return " | ".join(parts) if parts else ""


def summarize_headlines(items: list[dict[str, Any]]) -> str:
    """Take a list of news items and produce a single summary headline via LLM."""
    if not items:
        return ""

    headlines = [f"- {it.get('title', '')[:100]}" for it in items[:8]]
    headlines_text = "\n".join(headlines)

    try:
        response = _chat_completion(
            model=DEFAULT_MODEL,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are a senior news editor. Given a list of breaking news headlines, "
                        "produce a single concise summary headline (max 100 characters) that captures the main story. "
                        "Return ONLY the headline text, no quotes, no explanation."
                    ),
                },
                {
                    "role": "user",
                    "content": f"Headlines:\n{headlines_text}",
                },
            ],
            max_tokens=50,
        )
        summary = (response.choices[0].message.content or "").strip()
        return f"{summary} — {len(items)} stories"
    except Exception as e:
        print(f"[news] LLM summarization failed: {e}", file=sys.stderr)
        return f"{len(items)} breaking news items — see Slack"


def analyze(url_or_text: str) -> dict[str, Any]:
    try:
        response = _chat_completion(
            model=DEFAULT_MODEL,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are a senior OSINT analyst conducting deep-dive analysis of a news story. "
                        "Provide: (1) Executive summary, (2) Key entities identified, "
                        "(3) Threat/impact assessment, (4) Second-order effects, "
                        "(5) Recommended follow-up actions. Be concise and actionable."
                    ),
                },
                {
                    "role": "user",
                    "content": f"Analyze this story:\n{url_or_text}",
                },
            ],
            max_tokens=1000,
        )
        return {
            "analysis": (response.choices[0].message.content or "").strip(),
            "source": url_or_text,
        }
    except Exception as e:
        return {"error": str(e), "source": url_or_text}

"""Senior analyst OSINT agent — LLM entity extraction and story analysis."""

from __future__ import annotations

import os
import sys
from typing import Any

import litellm

DEFAULT_MODEL = os.environ.get("NANOBOT_NEWS_MODEL", "ollama/minimax-m2.7:cloud")


def extract_entities(item: dict[str, Any]) -> dict[str, Any]:
    title = item.get("title", "")
    snippet = item.get("snippet", "")
    tags = item.get("osint_tags", [])
    score = item.get("score", 0)

    if not title:
        return item

    try:
        response = litellm.acompletion(
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
            json_schema=True,
        )
        content = response.choices[0].message.content.strip()
        if content.startswith("```"):
            content = content.split("```")[1]
            if content.startswith("json"):
                content = content[4:]
        result: dict[str, Any] = eval(content)
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


def analyze(url_or_text: str) -> dict[str, Any]:
    try:
        response = litellm.acompletion(
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
            "analysis": response.choices[0].message.content.strip(),
            "source": url_or_text,
        }
    except Exception as e:
        return {"error": str(e), "source": url_or_text}

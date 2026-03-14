"""Hindsight recall tool for long-term memory search."""

from typing import Any

from nanobot.agent.tools.base import Tool

from nanobot.memory.hindsight_client import recall_memory


class HindsightRecallTool(Tool):
    """Tool that queries Hindsight for long-term memories. Registered only when HINDSIGHT_API_URL is set."""

    name = "recall_hindsight"
    description = (
        "Search Hindsight long-term memory by natural language query. "
        "Use when you need to recall past facts, experiences, or context that may have been learned over time. "
        "Complements search_memory (SQLite) with richer semantic and temporal recall."
    )
    parameters = {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Natural language search query (e.g. 'What does the user prefer for X?', 'Events in June')"},
            "max_tokens": {"type": "integer", "description": "Max tokens in results (optional, default from Hindsight)", "minimum": 256, "maximum": 32768},
        },
        "required": ["query"],
    }

    async def execute(self, query: str, max_tokens: int | None = None, **kwargs: Any) -> str:
        results = await recall_memory(query=query, max_tokens=max_tokens)
        if not results:
            return f"No Hindsight memories matched: {query}"
        lines = [f"Hindsight recall for: {query}\n"]
        for i, r in enumerate(results, 1):
            content = r.get("content", str(r))
            fact_type = r.get("type")
            suffix = f" (type: {fact_type})" if fact_type else ""
            lines.append(f"{i}.{suffix}")
            lines.append(f"   {content}")
        return "\n".join(lines)

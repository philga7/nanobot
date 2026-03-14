# Tool Usage Notes

Tool signatures are provided automatically via function calling.
This file documents non-obvious constraints and usage patterns.

## exec — Safety Limits

- Commands have a configurable timeout (default 60s)
- Dangerous commands are blocked (rm -rf, format, dd, shutdown, etc.)
- Output is truncated at 10,000 characters
- `restrictToWorkspace` config can limit file access to the workspace

## cron — Scheduled Reminders

- Please refer to cron skill for usage.

## recall_hindsight — Hindsight Long-term Memory (when enabled)

- Natural language search over retained memories. Complements `search_memory` (SQLite) with richer semantic recall.
- Use for queries like "What does the user prefer for X?" or "What happened in June?"

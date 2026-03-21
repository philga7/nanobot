# Agents Guide

## Project Overview

nanobot is a lightweight personal AI assistant framework written in Python 3.11+.

## Tech Stack

- **Runtime**: Python 3.11+
- **AI Integration**: litellm
- **Data Validation**: pydantic, pydantic-settings
- **Async**: asyncio, websockets
- **CLI**: typer
- **Testing**: pytest with asyncio_mode = "auto"
- **Linting/Formatting**: ruff (line-length: 100)

## Key Commands

```bash
# Install with dev dependencies
pip install -e ".[dev]"

# Run tests
pytest

# Lint
ruff check nanobot/

# Format
ruff format nanobot/
```

## Project Structure

```
nanobot/
├── agent/          # Core agent logic
├── bus/            # Event bus
├── channels/       # Platform integrations (telegram, slack, dingtalk, etc.)
├── cli/            # CLI commands (typer-based)
├── config/         # Configuration management
├── cron/           # Scheduled tasks
├── heartbeat/      # Health checks
├── memory/         # Conversation memory
├── providers/      # LLM provider implementations
├── security/       # Security utilities
├── session/        # Session management
├── skills/         # Agent skills
├── templates/      # Message/prompt templates
└── utils/          # General utilities
```

## Code Conventions

- Line length: 100 characters
- Target: Python 3.11+
- Ruff rules: E, F, I, N, W (E501 ignored)
- Async: uses `asyncio` throughout
- Prefer readable, simple code over clever code
- Focus patches over broad rewrites
- New abstractions should clearly reduce complexity

## Branching Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Stable releases |
| `nightly` | Experimental features |

- New features → target `nightly`
- Bug fixes → target `main`
- When in doubt → target `nightly`

## Architecture Notes

- Bridge directory is force-included in wheel builds as `nanobot/bridge`
- Template and skills directories are included in package data

# Agents Guide

## Project Overview

nanobot is a lightweight personal AI assistant framework written in Python 3.11+.

## Fork context (this repo)

This workspace is **[philga7/nanobot](https://github.com/philga7/nanobot)**, a fork of **[HKUDS/nanobot](https://github.com/HKUDS/nanobot)**. `upstream` should point at HKUDS; merge or rebase `upstream/main` into this fork’s `main` when you want upstream fixes and features (see [docs/WREN_UPDATE_WORKFLOW.md](docs/WREN_UPDATE_WORKFLOW.md) for a full rollout checklist).

**Fork-specific areas** (treat as first-class when changing behavior or docs):

- **`nanobot/skills/osint/`** — shell-driven OSINT briefing (`brief.sh`, `deliver.sh`, `sources/`), desk routing (intel / investing / weather), JSON handoff for agent-written Slack briefs.
- **Instance examples** — `config.wrenair.example.json`, `config.wrenvps.example.json`, `config.wrenpro.example.json` plus [INSTANCES.md](INSTANCES.md).
- **Compose overlays** — `docker-compose.wrenair.yml`, `docker-compose.wrenvps.yml`, `docker-compose.wrenpro.yml`, [DOCKER.md](DOCKER.md), and `deploy/news-stack/` where relevant.
- **Operator docs** — [docs/WREN_UPDATE_WORKFLOW.md](docs/WREN_UPDATE_WORKFLOW.md), [docs/NEWS_STACK_ENV_REFERENCE.md](docs/NEWS_STACK_ENV_REFERENCE.md).

## Tech Stack

- **Runtime**: Python 3.11+
- **AI Integration**: OpenAI + Anthropic SDKs (OpenAI-compatible providers unified in `OpenAICompatProvider`)
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
├── skills/         # Agent skills (includes fork OSINT briefing under skills/osint/)
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

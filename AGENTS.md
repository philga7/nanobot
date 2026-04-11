# Agents Guide

## Project Overview

nanobot is a lightweight personal AI assistant framework written in Python 3.11+.

## Fork context (this repo)

This workspace is **[philga7/nanobot](https://github.com/philga7/nanobot)**, a **community fork** of **[HKUDS/nanobot](https://github.com/HKUDS/nanobot)**. It is not affiliated with upstream; coordinate **upstream-bound** changes with HKUDS when appropriate.

Configure git **`upstream`** to HKUDS and merge or rebase **`upstream/main`** into this fork’s **`main`** to pick up upstream fixes and features. For a detailed multi-host rollout checklist, see [docs/WREN_UPDATE_WORKFLOW.md](docs/WREN_UPDATE_WORKFLOW.md).

**Fork-specific areas** (treat as first-class when changing behavior or docs):

- **`nanobot/skills/osint/`** — shell-driven OSINT briefing (`brief.sh`, `deliver.sh`, `sources/`), desk routing (intel / investing / weather), JSON handoff for agent-written Slack briefs.
- **Multi-instance examples** — `config.*.example.json` in the repo root and [INSTANCES.md](INSTANCES.md).
- **Compose overlays** — `docker-compose.*.yml` in the repo root (see [DOCKER.md](DOCKER.md)), plus `deploy/news-stack/` where relevant.
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
├── skills/         # Agent skills (includes OSINT briefing under skills/osint/ in this fork)
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

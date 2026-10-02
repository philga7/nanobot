# Working on nanobot

The Python gateway owns agent execution, sessions, tools, memory, and security policy. WebUI and TUI share that runtime; keep execution and policy out of the clients.

## Fork context (this repo)

This workspace is **[philga7/nanobot](https://github.com/philga7/nanobot)** — a **personal fork** of **[HKUDS/nanobot](https://github.com/HKUDS/nanobot)** with **maintainer-specific** customizations (OSINT skill, deployment docs, cron integration, etc.). It is not the upstream project.

Configure git **`upstream`** to HKUDS and merge or rebase **`upstream/main`** into this fork's **`main`** to pick up upstream fixes and features. For a detailed multi-host rollout checklist, see [docs/WREN_UPDATE_WORKFLOW.md](docs/WREN_UPDATE_WORKFLOW.md).

**Fork-specific areas** (treat as first-class when changing behavior or docs):

- **`nanobot/skills/osint/`** — shell-driven OSINT briefing (`brief.sh`, `deliver.sh`, `sources/`), desk routing (intel / investing / weather), JSON handoff for agent-written Slack briefs.
- **Multi-instance examples** — `config.*.example.json` in the repo root and [INSTANCES.md](INSTANCES.md).
- **Compose overlays** — `docker-compose.*.yml` in the repo root (see [DOCKER.md](DOCKER.md)), plus `deploy/news-stack/` where relevant.
- **Operator docs** — [docs/WREN_UPDATE_WORKFLOW.md](docs/WREN_UPDATE_WORKFLOW.md), [docs/NEWS_STACK_ENV_REFERENCE.md](docs/NEWS_STACK_ENV_REFERENCE.md).

## Task-specific guidance

| When working on | Read |
| --- | --- |
| Core boundaries, extensions, or internal types | [`.agent/design.md`](.agent/design.md) |
| Refactoring, fallbacks, or test selection | [`.agent/simplify.md`](.agent/simplify.md) |
| Path permissions, HTTP/MCP, or shell isolation | [`.agent/security.md`](.agent/security.md) |
| Dependency setup, WebUI transport, config, Windows, prompts, or persistence | [`.agent/gotchas.md`](.agent/gotchas.md) |
| Reusing verification evidence | [`.agent/workflow.md`](.agent/workflow.md) |
| WebUI/host compatibility | [`.agent/review-guide.md`](.agent/review-guide.md) |
| Contribution or publication | [`CONTRIBUTING.md`](CONTRIBUTING.md), [`docs/releasing.md`](docs/releasing.md) |

## Development commands

```bash
# Python: run single test / lint
pytest tests/test_openai_api.py::test_function -v
ruff check nanobot/

# Strict type checking (matches CI)
uv sync --all-extras --dev
uv run --no-sync python -m scripts.install_channel_dependencies --all-channels
uv run --no-sync basedpyright

# WebUI: dev server (proxies API/WS to gateway :8765), build, test
# Build outputs to ../nanobot/web/dist (bundled into the Python wheel)
cd webui && bun run dev      # or NANOBOT_API_URL=... bun run dev
cd webui && bun run build
cd webui && bun run test

# Gateway
nanobot gateway
```

## Development constraints

- Analyze the required behavior, state ownership, and root cause before extending existing code. Refactor when the structure causes the problem; a smaller diff does not justify another fallback.
- Do not add defensive tests for hypothetical internal states or unsupported combinations. Each new test needs a reachable path and a meaningful contract to protect.
- Do not run `ruff format`; mechanical formatting obscures git blame and creates unrelated diffs. This constraint takes precedence over the optional touched-file formatting in `CONTRIBUTING.md`.

<div align="center">
  <img src="nanobot_logo.png" alt="nanobot" width="420">
  <h1>nanobot</h1>
  <p><strong>Community fork</strong> of <a href="https://github.com/HKUDS/nanobot">HKUDS/nanobot</a></p>
  <p>
    <img src="https://img.shields.io/badge/python-≥3.11-blue" alt="Python">
    <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
    <a href="https://github.com/philga7/nanobot"><img src="https://img.shields.io/badge/GitHub-philga7%2Fnanobot-181717?logo=github" alt="Repository"></a>
    <a href="https://nanobot.wiki/docs/0.1.5/getting-started/nanobot-overview"><img src="https://img.shields.io/badge/Docs-upstream%20wiki-blue?style=flat&logo=readthedocs&logoColor=white" alt="Upstream docs"></a>
  </p>
</div>

This repo is **[philga7/nanobot](https://github.com/philga7/nanobot)** — an **unofficial, community-maintained fork** of **[HKUDS/nanobot](https://github.com/HKUDS/nanobot)**. It is **not affiliated** with the upstream project; use this repository for **fork-specific** issues and pull requests. It tracks `upstream/main` so you still benefit from upstream channels, memory, providers, and fixes.

## What this fork adds

- **OSINT briefing skill** (`nanobot/skills/osint/`) — layered pipeline: 30+ open APIs, RSS, and Twitter/X signals; caching; **three-desk** routing (intel, investing, weather) with topic weighting, geo filters, and multi-model forecasts; `deliver.sh --json` plus **agent-synthesized** narrative briefs for scheduled Slack (instead of raw jq-only assembly for cron delivery).
- **Cron integration** — hooks such as `agent_turn` and URL hints so scheduled jobs can use the same agent stack as interactive chat.
- **Multi-instance playbooks** — [INSTANCES.md](INSTANCES.md) describes separate configs and data directories, **systemd** and **launchd** service examples, and per-role **example configs** in the repo root (`config.*.example.json`).
- **Docker overlays for local search** — [DOCKER.md](DOCKER.md) and optional `docker-compose.*.yml` files in the repo root run **SearXNG** (and related infra) while keeping the gateway on the host.
- **Operator docs** — [docs/WREN_UPDATE_WORKFLOW.md](docs/WREN_UPDATE_WORKFLOW.md) (syncing upstream and rolling out across hosts), [docs/NEWS_STACK_ENV_REFERENCE.md](docs/NEWS_STACK_ENV_REFERENCE.md) (env vars for APIs and news stack), and [nanobot/skills/osint/SKILL.md](nanobot/skills/osint/SKILL.md) for triggers, desk config, and shell entrypoints (`brief.sh`, `deliver.sh`).

## Benefits

- **One codebase** for CLI, gateway channels, cron, and scripted briefs — aligned with upstream’s agent model, memory (including Dream), MCP, and providers.
- **Clear instance boundaries** — documented patterns for multiple deployments (e.g. desktop gateway, VPS, offline-first).
- **Structured open data** — APIs, feeds, and social signals feed JSON the agent can reason over, with desk-specific Slack output.

## Quick start (this fork)

```bash
git clone https://github.com/philga7/nanobot.git
cd nanobot
python3.11 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"

nanobot onboard
# Edit ~/.nanobot/config.json (API keys, model, channels)
nanobot gateway
```

**Upstream package** (stable release, no fork-only features):

```bash
pip install nanobot-ai
```

## Documentation map

| Topic | Where |
|--------|--------|
| Full product guide (channels, providers, memory, security) | [nanobot.wiki](https://nanobot.wiki/docs/0.1.5/getting-started/nanobot-overview) and upstream [README](https://github.com/HKUDS/nanobot/blob/main/README.md) |
| Multi-instance setup (systemd / launchd) | [INSTANCES.md](INSTANCES.md) |
| SearXNG / Compose | [DOCKER.md](DOCKER.md) |
| Multi-host update workflow | [docs/WREN_UPDATE_WORKFLOW.md](docs/WREN_UPDATE_WORKFLOW.md) |
| OSINT / news stack environment | [docs/NEWS_STACK_ENV_REFERENCE.md](docs/NEWS_STACK_ENV_REFERENCE.md) |
| OSINT skill behavior and desk config | [nanobot/skills/osint/SKILL.md](nanobot/skills/osint/SKILL.md) |

## Contributing

- **This fork:** open issues and PRs here for OSINT, deployment docs, and other fork-specific work.
- **Upstream:** bug fixes and general features may belong in [HKUDS/nanobot](https://github.com/HKUDS/nanobot); see upstream [CONTRIBUTING.md](CONTRIBUTING.md).
- Branching matches upstream convention: **`main`** for integrated work, **`nightly`** for experiments — details in [AGENTS.md](AGENTS.md).

---

nanobot is for **educational, research, and technical exchange** purposes only. It is unrelated to crypto and does not involve any official token or coin.

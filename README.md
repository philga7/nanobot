<div align="center">
  <img src="nanobot_logo.png" alt="nanobot" width="420">
  <h1>nanobot (Wren fork)</h1>
  <p>
    <img src="https://img.shields.io/badge/python-≥3.11-blue" alt="Python">
    <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
    <a href="https://github.com/philga7/nanobot"><img src="https://img.shields.io/badge/repo-philga7%2Fnanobot-181717?logo=github" alt="This fork"></a>
    <a href="https://nanobot.wiki/docs/0.1.5/getting-started/nanobot-overview"><img src="https://img.shields.io/badge/Docs-upstream%20wiki-blue?style=flat&logo=readthedocs&logoColor=white" alt="Upstream docs"></a>
  </p>
</div>

This repository is **[philga7/nanobot](https://github.com/philga7/nanobot)** — a personal fork of **[HKUDS/nanobot](https://github.com/HKUDS/nanobot)** (the ultra-lightweight personal AI agent framework). It tracks upstream releases and adds automation, OSINT-style briefing, and deployment notes for multiple dedicated instances (“WrenAir”, “WrenVPS”, “WrenPro”).

## What this fork adds

- **OSINT briefing skill** (`nanobot/skills/osint/`) — layered intel pipeline: 30+ open APIs, RSS, and Twitter/X signals; caching; **three-desk** routing (intel, investing, weather) with topic weighting, geo filters, and multi-model forecasts; `deliver.sh --json` plus **agent-synthesized** narrative briefs for scheduled Slack (instead of raw jq dumps for cron delivery).
- **Cron integration** — operational hooks such as `agent_turn` and URL hints so scheduled jobs can drive the same agent stack you use interactively.
- **Multi-instance playbooks** — [INSTANCES.md](INSTANCES.md) documents separate configs and data dirs (`~/.wrenair`, `~/.wrenvps`, `~/.wrenpro`), native **systemd** / **launchd** services, and example configs: `config.wrenair.example.json`, `config.wrenvps.example.json`, `config.wrenpro.example.json`.
- **Docker overlays for local search** — [DOCKER.md](DOCKER.md) and `docker-compose.wrenair.yml` / `docker-compose.wrenvps.yml` / `docker-compose.wrenpro.yml` stand up **SearXNG** (and related infra) while keeping the gateway on the host.
- **Operator docs** — [docs/WREN_UPDATE_WORKFLOW.md](docs/WREN_UPDATE_WORKFLOW.md) (rollout across machines), [docs/NEWS_STACK_ENV_REFERENCE.md](docs/NEWS_STACK_ENV_REFERENCE.md) (env vars for APIs and news stack), plus the OSINT skill’s `SKILL.md` for triggers, desk config, and shell entrypoints (`brief.sh`, `deliver.sh`).
- **Regular upstream merges** — `main` rebases/merges `upstream/main` so you keep WebSocket channels, unified session, provider fixes, and the rest of the upstream feature set.

## Benefits

- **One codebase** for CLI chat, gateway channels, cron, and scripted briefs — with upstream’s channels, memory (including Dream), MCP, and providers unchanged in spirit.
- **Operational clarity** — instance boundaries, compose files, and env references are documented for repeat deploys (Mac, VPS, air-gapped-style local stack).
- **Rich open-source picture** — APIs, feeds, and social signals feed structured JSON the agent can reason over, with desk-specific Slack outputs.

## Quick start (from this fork)

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

For **PyPI-stable** installs of the upstream package only:

```bash
pip install nanobot-ai
```

## Documentation map

| Topic | Where |
|--------|--------|
| Full product guide (channels, providers, memory, security) | [nanobot.wiki](https://nanobot.wiki/docs/0.1.5/getting-started/nanobot-overview) and upstream [README](https://github.com/HKUDS/nanobot/blob/main/README.md) |
| Wren multi-instance + systemd / launchd | [INSTANCES.md](INSTANCES.md) |
| SearXNG / compose | [DOCKER.md](DOCKER.md) |
| Deploying updates across machines | [docs/WREN_UPDATE_WORKFLOW.md](docs/WREN_UPDATE_WORKFLOW.md) |
| OSINT env and news stack | [docs/NEWS_STACK_ENV_REFERENCE.md](docs/NEWS_STACK_ENV_REFERENCE.md) |
| OSINT skill behavior and desk config | [nanobot/skills/osint/SKILL.md](nanobot/skills/osint/SKILL.md) |

## Contributing / branching

This fork uses the same branch discipline as upstream when contributing back: **`main`** for stable-ish integration, **`nightly`** for experimental work — see [AGENTS.md](AGENTS.md) and upstream [CONTRIBUTING.md](CONTRIBUTING.md).

---

nanobot is for **educational, research, and technical exchange** purposes only. It is unrelated to crypto and does not involve any official token or coin.

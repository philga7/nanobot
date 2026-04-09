## Wren Update Workflow

This documents how to roll out changes from `~/workspace/nanobot` to WrenAir (macOS), WrenVPS (remote VPS), and WrenPro (DoD laptop).

---

## 1. Update and test the nanobot repo (local)

From your Mac, in `~/workspace/nanobot`:

```bash
cd ~/workspace/nanobot

# 1) Pull latest upstream into main and push to your fork
git fetch upstream
git checkout main
git merge upstream/main
pytest -q   # or: source .venv/bin/activate && pytest -q
git push origin main
```

At this point:

- WrenAir (which runs from `~/workspace/nanobot`) can use the new code after a restart.
- WrenVPS can pull the same `main` and restart its service.

---

## 2. WrenAir (macOS, launchd + log file)

### 2.1 Restart WrenAir after updating code

WrenAir is a `launchd` agent with label:

- `ai.nanobot.gateway.wrenair`

To restart it on your Mac:

```bash
launchctl kickstart -k gui/$UID/ai.nanobot.gateway.wrenair
```

You can confirm it is loaded:

```bash
launchctl list | grep ai.nanobot.gateway.wrenair
```

### 2.2 View WrenAir logs

WrenAir writes to a regular log file:

```bash
tail -f ~/Library/Logs/nanobot-gateway-wrenair.log
```

Common variants:

```bash
# Scrollable view (jump to end with G)
less +G ~/Library/Logs/nanobot-gateway-wrenair.log

# Quickly see recent errors / warnings
grep -i 'error' ~/Library/Logs/nanobot-gateway-wrenair.log | tail
grep -i 'warn'  ~/Library/Logs/nanobot-gateway-wrenair.log | tail
```

---

## 3. WrenVPS (Linux VPS, systemd)

### 3.1 Identify the systemd unit (already known)

On the VPS:

- Unit name: `nanobot-gateway-wrenvps.service`

You can re-discover it if needed:

```bash
systemctl list-units '*wren*'
systemctl list-unit-files | grep -i wren
```

### 3.2 Update code and environment on WrenVPS

On the VPS:

```bash
ssh <user>@<wrenvps-host>

cd /root/projects/nanobot   # adjust if the repo lives elsewhere
git pull origin main

source .venv/bin/activate   # or the venv used by the service
pip install -e .            # refresh installed package from the updated repo
```

### 3.3 Restart the WrenVPS service

Still on the VPS:

```bash
sudo systemctl restart nanobot-gateway-wrenvps.service
sudo systemctl status nanobot-gateway-wrenvps.service
```

### 3.4 View WrenVPS logs

Use `journalctl` for systemd-managed logs:

```bash
# Live stream (like tail -f)
sudo journalctl -u nanobot-gateway-wrenvps.service -f

# Last 200 lines
sudo journalctl -u nanobot-gateway-wrenvps.service -n 200

# Logs from the last hour
sudo journalctl -u nanobot-gateway-wrenvps.service --since "1 hour ago"
```

---

## 4. WrenPro (DoD laptop, Ubuntu, local-only)

WrenPro runs entirely local — Ollama for LLM, SearXNG in Docker for search. No cloud keys or remote hosts involved.

### 4.1 Update code on the DoD laptop

```bash
cd ~/workspace/nanobot
git pull origin main

source .venv/bin/activate
pip install -e .
```

### 4.2 Update SearXNG container (if image updated)

```bash
docker compose -f docker-compose.wrenpro.yml pull
docker compose -f docker-compose.wrenpro.yml up -d
```

### 4.3 Update Ollama models (if new versions available)

```bash
ollama pull gemma4:27b
ollama pull gemma4:4b
```

### 4.4 Restart WrenPro

If running as a systemd user service:

```bash
systemctl --user restart nanobot-gateway-wrenpro.service
systemctl --user status nanobot-gateway-wrenpro.service
```

If running manually:

```bash
# Stop the existing process (Ctrl-C or kill), then:
source ~/dev/nanobot-wrenpro/venv/bin/activate
nanobot gateway --config ~/.wrenpro/config.json
```

### 4.5 View WrenPro logs

```bash
# If systemd user service:
journalctl --user -u nanobot-gateway-wrenpro.service -f

# Last 200 lines:
journalctl --user -u nanobot-gateway-wrenpro.service -n 200
```

---

## 5. Quick reference

- **Local WrenAir (macOS)**
  - Restart: `launchctl kickstart -k gui/$UID/ai.nanobot.gateway.wrenair`
  - Logs (live): `tail -f ~/Library/Logs/nanobot-gateway-wrenair.log`

- **Remote WrenVPS (Linux VPS)**
  - Update code:
    - `cd /root/projects/nanobot && git pull origin main`
    - `source .venv/bin/activate && pip install -e .`
  - Restart: `sudo systemctl restart nanobot-gateway-wrenvps.service`
  - Logs (live): `sudo journalctl -u nanobot-gateway-wrenvps.service -f`

- **Local WrenPro (DoD laptop, Ubuntu)**
  - Update code:
    - `cd ~/workspace/nanobot && git pull origin main`
    - `source .venv/bin/activate && pip install -e .`
  - Update SearXNG: `docker compose -f docker-compose.wrenpro.yml pull && docker compose -f docker-compose.wrenpro.yml up -d`
  - Update models: `ollama pull gemma4:27b && ollama pull gemma4:4b`
  - Restart (systemd): `systemctl --user restart nanobot-gateway-wrenpro.service`
  - Logs (live): `journalctl --user -u nanobot-gateway-wrenpro.service -f`


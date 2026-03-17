## WrenAir & WrenVPS Update Workflow

This documents how to roll out changes from `~/workspace/nanobot` to both WrenAir (macOS) and WrenVPS (remote VPS).

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

## 4. Quick reference

- **Local WrenAir (macOS)**
  - Restart: `launchctl kickstart -k gui/$UID/ai.nanobot.gateway.wrenair`
  - Logs (live): `tail -f ~/Library/Logs/nanobot-gateway-wrenair.log`

- **Remote WrenVPS (Linux VPS)**
  - Update code:
    - `cd /root/projects/nanobot && git pull origin main`
    - `source .venv/bin/activate && pip install -e .`
  - Restart: `sudo systemctl restart nanobot-gateway-wrenvps.service`
  - Logs (live): `sudo journalctl -u nanobot-gateway-wrenvps.service -f`


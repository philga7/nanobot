---
name: net-monitor
description: >-
  Monitors VPS internet, WireGuard (wg-home), Tailscale, and home LAN
  reachability from shell probes; emits JSON for agent formatting and optional
  ntfy alerts with dedupe. Use when the user asks about home network status,
  VPN health, WireGuard, Tailscale funnel, "how's my network", "net status",
  or wants to install or tune this monitoring skill on the VPS.
metadata: {"nanobot":{"emoji":"📡","requires":{"bins":["bash","curl","jq","ping","python3"]}}}
---

# Home Network Monitor (`net-monitor`)

Shell-first probes run **on the VPS** (where `wg` and `tailscale` exist). The
agent reads `scripts/check.sh` JSON for Telegram replies and can point cron at
`check.sh` + `scripts/alert.sh` for ntfy delivery.

## Triggers (on-demand)

- "How's my network?", "net status", "home VPN status", "wg-home health",
  "Tailscale funnel up?"

**Agent flow:** run `bash scripts/check.sh` from this skill directory (or pass
absolute paths), parse JSON, reply in a compact emoji summary with small tables
for internet / WireGuard / Tailscale / home (mirror the user’s OpenClaw-style
format: status lines, latency/loss, handshake age, funnel HTTP result).

## Scripts

| Script | Role |
|--------|------|
| `scripts/check.sh` | All probes → **one JSON object** on stdout |
| `scripts/alert.sh` | Reads that JSON (file path or stdin), maps severity → ntfy priority, dedupes |

```bash
cd /path/to/nanobot/nanobot/skills/net-monitor
bash scripts/check.sh | tee /tmp/net.json
bash scripts/alert.sh /tmp/net.json
bash scripts/check.sh | bash scripts/alert.sh --dry-run
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `NET_MONITOR_WG_IF` | `wg-home` | WireGuard interface name |
| `NET_MONITOR_HOME_ROUTER` | `192.168.4.1` | Home router (via WG routes) |
| `NET_MONITOR_WG_PEER` | `10.100.0.1` | WG peer / gateway ping |
| `NET_MONITOR_TS_FUNNEL_URL` | `https://srv930537.tail564951.ts.net` | Funnel probe URL |
| `NET_MONITOR_TAILSCALE_LOCAL_IP` | `100.86.27.28` | Recorded local MagicDNS / node IP |
| `NET_MONITOR_TAILSCALE_HOME_IP` | *(empty)* | Optional: ping a **home** Tailscale IP |
| `NET_MONITOR_NTFY_URL` | *(empty)* | Full publish URL (topic secret in path if used) |
| `NET_MONITOR_CACHE_DIR` | `<skill>/cache` | Dedupe state directory |
| `NET_MONITOR_CACHE_FILE` | `.../last_alert.json` | Dedupe JSON |
| `NET_MONITOR_DEDUPE_SEC` | `1800` | Suppress repeat alerts for same condition set |

Set `NET_MONITOR_TAILSCALE_HOME_IP` on the VPS when you have a stable home
device IP; without it, `tailscale.home_node_reachable` stays `null` and only
WireGuard + funnel checks apply to “home”.

## Alert semantics (`alert.sh`)

| Keys (combined) | Severity | ntfy priority |
|-----------------|----------|----------------|
| `internet_down` | CRITICAL | 5 (urgent) |
| `home_unreachable` | CRITICAL | 5 |
| `wireguard_down` | CRITICAL | 5 |
| `tailscale_down`, `wireguard_stale` | WARNING | 4 |
| `funnel_down` | LOW | 2 |
| All clear after fault | INFO | 3 + “Network restored” |

Dedupe: identical sorted `keys` within `NET_MONITOR_DEDUPE_SEC` → no second
push. `--dry-run` prints the ntfy payload without `curl`.

**Daily reassurance (7:00 America/New_York):** run `check.sh`, then
`bash scripts/alert.sh --daily /tmp/net.json` — sends a summary at default
priority (set `NET_MONITOR_NTFY_URL` first). Dedupe logic is bypassed for
`--daily`.

## Cron (VPS)

Every 15 minutes:

```cron
*/15 * * * * cd /path/to/nanobot/nanobot/skills/net-monitor && . /path/to/.env && bash scripts/check.sh | tee /tmp/net-monitor.json | bash scripts/alert.sh /tmp/net-monitor.json
```

Daily 7:00 ET:

```cron
0 7 * * * cd /path/to/nanobot/nanobot/skills/net-monitor && . /path/to/.env && bash scripts/check.sh > /tmp/net-monitor.json && bash scripts/alert.sh --daily /tmp/net-monitor.json
```

Load `NET_MONITOR_*` and `NET_MONITOR_NTFY_URL` from a root-only env file or
systemd environment.

## JSON schema (`check.sh`)

Top-level: `timestamp`, `internet`, `wireguard`, `tailscale`, `home_network`,
`alert` (always `null`; alerting is `alert.sh`).

- **internet:** `status` (`up` \| `degraded` \| `down`), `latency_ms`,
  `packet_loss_pct`, `dns` (`ok` \| `error`)
- **wireguard:** `status` (`connected` \| `degraded` \| `down` \| `never` \|
  `absent` \| `no_peer`), `last_handshake_ago_s`, `peer_reachable`,
  `transfer_*_mb` (null when absent)
- **tailscale:** `status`, `local_ip`, `funnel_reachable`, `home_node_reachable`
- **home_network:** `reachable`, `via` (`wireguard` \| `tailscale` \| `both` \| `none`)

## Operating notes

- **Alert-only v1:** no auto-restart of WireGuard; add remediation later if desired.
- **ISP gateway ICMP blocked** is normal; probes use public IPs and home targets
  from your design doc, not `31.97.129.254`.
- **Phase 2** (external nmap, fail2ban, ACL review) is a separate skill; do not
  bundle into this directory.

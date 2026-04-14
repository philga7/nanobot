---
name: net-audit
description: >-
  Monitors VPS and home network security from the VPS, including tunnel health,
  external exposure, DNS integrity, firewall posture, SSH hardening, TLS expiry,
  auth log trends, outbound anomalies, persistence drift, and patch hygiene.
metadata: {"nanobot":{"emoji":"🛡️","requires":{"bins":["bash","curl","jq","ping","openssl","nmap","dig"]}}}
---

# Net Audit Skill

Monitors VPS and home network security. Runs from the VPS and checks internet health,
VPN tunnel integrity, firewall posture, SSH hardening, TLS certificate health, auth log
activity, outbound anomalies, and persistence integrity.

## Commands

- `net-audit check`              — Full probe, JSON to stdout
- `net-audit alert`              — Run check, evaluate alerts, send ntfy if needed
- `net-audit report`             — Run check, output A–F graded report card
- `net-audit cve-lookup <v> <m>` — Check vendor/model against CISA KEV

## Cron

- Every 15 min: net-audit alert (health check)
- Daily 7AM ET: net-audit report (sent via ntfy)

## What This Audits That External Scanners Cannot

- Auth log brute-force trends (journalctl)
- Outbound connection anomaly detection (ss)
- Cron job and systemd timer change detection
- SUID binary baseline diff
- Pending security patches + reboot-required state
- WireGuard private key file permissions
- Docker/UFW iptables bypass detection
- SSH authorized_keys change detection

## Alert Severity Levels

CRITICAL (max) → WARN (high) → LOW (low) → INFO (default)
See this skill's alert table for full condition list.

## Script Usage

```bash
cd /root/projects/nanobot/nanobot/skills/net-audit
bash scripts/check.sh | jq .
bash scripts/check.sh | bash scripts/report.sh
bash scripts/alert.sh
bash scripts/cve-lookup.sh "OpenSSH" "openssh"
```

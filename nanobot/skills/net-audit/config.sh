#!/usr/bin/env bash
# config.sh — NanoBot net-audit configuration

# ── Tunnels ─────────────────────────────────────────────────────────────────
WG_INTERFACE="wg-home"
WG_PEER_IP="10.100.0.1"
WG_REMOTE_ENDPOINT="40.133.170.212:51820"

# ── Home Network ─────────────────────────────────────────────────────────────
HOME_ROUTER_IP="192.168.4.1"

# ── Tailscale ────────────────────────────────────────────────────────────────
TAILSCALE_HOME_IP="100.86.27.28"
TAILSCALE_FUNNEL_URL="https://srv930537.tail564951.ts.net"

# ── DNS ──────────────────────────────────────────────────────────────────────
TRUSTED_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DNS_TEST_DOMAIN="google.com"
DNS_TEST_DOMAIN_SECONDARY="example.com"
ISP_GATEWAY="31.97.129.254"

# ── Port Policy ───────────────────────────────────────────────────────────────
# Post-hardening defaults: SSH on non-standard port, HTTPS, WireGuard, HTTP (redirect).
EXPECTED_OPEN_PORTS=("2222" "443" "51820" "80")

# Docker-published ports treated as intentional when UFW is bypassed (iptables DNAT).
ALLOWED_DOCKER_PORTS=("80" "443" "3000" "6333" "6334" "8080" "18791")

# ── Alert Thresholds ──────────────────────────────────────────────────────────
WG_STALE_THRESHOLD_S=120
WG_DOWN_THRESHOLD_S=300
SSH_BRUTE_WARN_THRESHOLD=50
SSH_BRUTE_CRIT_THRESHOLD=200
DEDUP_WINDOW_MIN=30
TLS_WARN_DAYS=14
TLS_CRIT_DAYS=3

# ── Trusted Outbound Destinations (CIDR or exact IP) ─────────────────────────
TRUSTED_OUTBOUND=("8.8.8.8" "1.1.1.1" "9.9.9.9" "40.133.170.212")

# ── Commercial Schema Fields (future multi-host support) ─────────────────────
HOST_ID="vps-primary"
HOST_LABEL="Primary VPS"

# ── CISA KEV ─────────────────────────────────────────────────────────────────
CISA_KEV_URL="https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
CISA_KEV_CACHE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cache/cisa-kev.json"
CISA_KEV_MAX_AGE_DAYS=7

# ── Alert Transport ───────────────────────────────────────────────────────────
ALERT_WEBHOOK_URL=""

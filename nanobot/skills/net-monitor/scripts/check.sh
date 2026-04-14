#!/usr/bin/env bash
# Home / VPS network probes. Prints one JSON object to stdout (requires jq).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${NET_MONITOR_WG_IF:=wg-home}"
: "${NET_MONITOR_HOME_ROUTER:=192.168.4.1}"
: "${NET_MONITOR_WG_PEER:=10.100.0.1}"
: "${NET_MONITOR_TS_FUNNEL_URL:=https://srv930537.tail564951.ts.net}"
: "${NET_MONITOR_TAILSCALE_LOCAL_IP:=100.86.27.28}"
# Optional: Tailscale IP of a device on the home LAN (if unset, home_via_ts is null).
: "${NET_MONITOR_TAILSCALE_HOME_IP:=}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

now_epoch() { date +%s; }

run_ping() {
  local host=$1
  local out
  if ! out="$(ping -c 3 "$host" 2>&1)"; then
    printf '%s' "$out"
    return 1
  fi
  printf '%s' "$out"
}

# Prints: loss_pct avg_ms (space-separated) on stdout; returns 0 if any reply received.
parse_ping_stats() {
  local out=$1
  local loss avg
  loss="$(printf '%s' "$out" | grep -oE '[0-9.]+% packet loss' | head -1 | tr -dc '0-9.')"
  loss="${loss%%.*}"
  [[ -z "$loss" ]] && loss="100"
  avg="$(printf '%s' "$out" | grep -E 'min/avg/max|round-trip' | grep -oE '[0-9.]+/[0-9.]+/[0-9.]+' | head -1 | cut -d/ -f2)"
  if [[ -z "$avg" || "$avg" == "" ]]; then avg="null"; fi
  printf '%s %s' "$loss" "$avg"
}

probe_ping() {
  local host=$1
  local out loss avg
  if ! out="$(run_ping "$host")"; then
    jq -nc --arg host "$host" \
      '{host: $host, ok: false, loss_pct: 100, latency_ms: null}'
    return
  fi
  read -r loss avg <<<"$(parse_ping_stats "$out")"
  local ok_j=true
  if [[ "${loss:-100}" -ge 100 ]] 2>/dev/null; then ok_j=false; fi
  if [[ "$avg" == "null" ]]; then ok_j=false; fi
  jq -nc \
    --arg host "$host" \
    --argjson ok "$ok_j" \
    --argjson loss "${loss:-100}" \
    --arg avg "$avg" \
    '{host: $host, ok: $ok, loss_pct: ($loss|tonumber? // 100),
      latency_ms: (if $avg == "null" then null else ($avg|tonumber) end)}'
}

internet_summary() {
  local a b combined_loss combined_lat up_count=0
  a="$(probe_ping "8.8.8.8")"
  b="$(probe_ping "1.1.1.1")"
  combined_loss="$(printf '%s\n%s\n' "$a" "$b" | jq -s 'map(.loss_pct) | max')"
  local lat_a lat_b
  lat_a="$(echo "$a" | jq '.latency_ms')"
  lat_b="$(echo "$b" | jq '.latency_ms')"
  if [[ "$lat_a" != "null" && "$lat_b" != "null" ]]; then
    combined_lat="$(jq -n --argjson x "$lat_a" --argjson y "$lat_b" '($x + $y) / 2')"
  elif [[ "$lat_a" != "null" ]]; then
    combined_lat="$lat_a"
  elif [[ "$lat_b" != "null" ]]; then
    combined_lat="$lat_b"
  else
    combined_lat="null"
  fi
  [[ "$(echo "$a" | jq '.ok')" == "true" ]] && up_count=$((up_count + 1))
  [[ "$(echo "$b" | jq '.ok')" == "true" ]] && up_count=$((up_count + 1))
  local status="up"
  [[ "$up_count" -eq 0 ]] && status="down"
  [[ "$up_count" -eq 1 ]] && status="degraded"
  local dns="error"
  if out="$(python3 -c "import socket; print(socket.gethostbyname(\"google.com\"))" 2>/dev/null)"; then
    dns="ok"
  fi
  jq -nc \
    --arg status "$status" \
    --argjson loss "$combined_loss" \
    --argjson lat "$combined_lat" \
    --arg dns "$dns" \
    '{status: $status, latency_ms: $lat, packet_loss_pct: $loss, dns: $dns}'
}

wg_section() {
  if ! command -v wg >/dev/null 2>&1; then
    jq -nc \
      --arg ifc "$NET_MONITOR_WG_IF" \
      '{interface: $ifc, status: "absent", last_handshake_ago_s: null, peer_reachable: null,
        transfer_down_mb: null, transfer_up_mb: null}'
    return
  fi
  if ! wg show "$NET_MONITOR_WG_IF" >/dev/null 2>&1; then
    jq -nc \
      --arg ifc "$NET_MONITOR_WG_IF" \
      '{interface: $ifc, status: "absent", last_handshake_ago_s: null, peer_reachable: null,
        transfer_down_mb: null, transfer_up_mb: null}'
    return
  fi
  local line rx tx hs now peer_ok
  now="$(now_epoch)"
  line="$(wg show "$NET_MONITOR_WG_IF" dump | awk 'NR>1 && $1 != "" {print; exit}')"
  if [[ -z "$line" ]]; then
    jq -nc --arg ifc "$NET_MONITOR_WG_IF" \
      '{interface: $ifc, status: "no_peer", last_handshake_ago_s: null, peer_reachable: null,
        transfer_down_mb: null, transfer_up_mb: null}'
    return
  fi
  rx="$(echo "$line" | awk '{print $6}')"
  tx="$(echo "$line" | awk '{print $7}')"
  hs="$(echo "$line" | awk '{print $5}')"
  local hs_status="connected" ago_json
  if [[ "$hs" -eq 0 ]]; then
    hs_status="never"
    ago_json=null
  else
    local ago_n=$((now - hs))
    ago_json=$ago_n
    if [[ "$ago_n" -gt 300 ]]; then
      hs_status="down"
    elif [[ "$ago_n" -gt 120 ]]; then
      hs_status="degraded"
    fi
  fi
  local peer_json
  peer_json="$(probe_ping "$NET_MONITOR_WG_PEER")"
  peer_ok="$(echo "$peer_json" | jq '.ok')"
  local down_mb up_mb
  down_mb="$(awk -v b="$rx" 'BEGIN {printf "%.2f", b/1024/1024}')"
  up_mb="$(awk -v b="$tx" 'BEGIN {printf "%.2f", b/1024/1024}')"
  jq -nc \
    --arg ifc "$NET_MONITOR_WG_IF" \
    --arg st "$hs_status" \
    --argjson ago "$ago_json" \
    --argjson peer_ok "$peer_ok" \
    --argjson down "$down_mb" \
    --argjson up "$up_mb" \
    '{interface: $ifc, status: $st, last_handshake_ago_s: $ago, peer_reachable: $peer_ok,
      transfer_down_mb: $down, transfer_up_mb: $up}'
}

tailscale_section() {
  if ! command -v tailscale >/dev/null 2>&1; then
    jq -nc \
      --arg ip "$NET_MONITOR_TAILSCALE_LOCAL_IP" \
      '{status: "absent", local_ip: $ip, funnel_reachable: null, home_node_reachable: null}'
    return
  fi
  local raw backend funnel_ok=true home_json=null funnel_http
  if ! raw="$(tailscale status --json 2>/dev/null)"; then
    jq -nc --arg ip "$NET_MONITOR_TAILSCALE_LOCAL_IP" \
      '{status: "error", local_ip: $ip, funnel_reachable: false, home_node_reachable: null}'
    return
  fi
  backend="$(echo "$raw" | jq -r '.Self.BackendState // "Unknown"')"
  local status="connected"
  [[ "$backend" != "Running" ]] && status="disconnected"
  if [[ -n "$NET_MONITOR_TS_FUNNEL_URL" ]]; then
    funnel_http="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$NET_MONITOR_TS_FUNNEL_URL" 2>/dev/null || true)"
    [[ "$funnel_http" =~ ^(2|3)[0-9][0-9]$ ]] || funnel_ok=false
  else
    funnel_ok=true
  fi
  if [[ -n "$NET_MONITOR_TAILSCALE_HOME_IP" ]]; then
    home_json="$(probe_ping "$NET_MONITOR_TAILSCALE_HOME_IP" | jq -c '.ok')"
  fi
  jq -nc \
    --arg st "$status" \
    --arg ip "$NET_MONITOR_TAILSCALE_LOCAL_IP" \
    --argjson funnel "$funnel_ok" \
    --argjson home "$home_json" \
    '{status: $st, local_ip: $ip, funnel_reachable: $funnel, home_node_reachable: $home}'
}

home_section() {
  local router_json peer_json r_ok p_ok
  router_json="$(probe_ping "$NET_MONITOR_HOME_ROUTER")"
  peer_json="$(probe_ping "$NET_MONITOR_WG_PEER")"
  r_ok="$(echo "$router_json" | jq '.ok')"
  p_ok="$(echo "$peer_json" | jq '.ok')"
  local reachable=false via="none"
  if [[ "$r_ok" == "true" ]]; then
    reachable=true
    via="wireguard"
  elif [[ "$p_ok" == "true" ]]; then
    reachable=true
    via="wireguard"
  fi
  if [[ -n "$NET_MONITOR_TAILSCALE_HOME_IP" ]]; then
    local ts_ok
    ts_ok="$(probe_ping "$NET_MONITOR_TAILSCALE_HOME_IP" | jq '.ok')"
    if [[ "$ts_ok" == "true" ]]; then
      reachable=true
      if [[ "$via" == "wireguard" ]]; then
        via="both"
      else
        via="tailscale"
      fi
    fi
  fi
  jq -nc --argjson r "$reachable" --arg via "$via" '{reachable: $r, via: $via}'
}

main() {
  local internet wg ts home ts_json
  internet="$(internet_summary)"
  wg="$(wg_section)"
  ts_json="$(tailscale_section)"
  home="$(home_section)"
  jq -nc \
    --arg ts "$(ts)" \
    --argjson internet "$internet" \
    --argjson wireguard "$wg" \
    --argjson tailscale "$ts_json" \
    --argjson home_network "$home" \
    '{timestamp: $ts, internet: $internet, wireguard: $wireguard, tailscale: $tailscale,
      home_network: $home_network, alert: null}'
}

main

#!/usr/bin/env bash
# report.sh — format net-audit JSON into graded report card
set -euo pipefail

input="$(cat)"
if [[ -z "${input// }" ]]; then
  echo "No JSON input provided to report.sh" >&2
  exit 1
fi

grade_external() {
  local n="$1"
  if [[ "$n" -eq 0 ]]; then echo A
  elif [[ "$n" -eq 1 ]]; then echo B
  elif [[ "$n" -le 3 ]]; then echo C
  elif [[ "$n" -le 5 ]]; then echo D
  else echo F; fi
}

grade_dns() {
  local status="$1" mm="$2" dnssec="$3"
  if [[ "$status" == "suspected" ]]; then echo F
  elif [[ "$mm" -ge 2 ]]; then echo D
  elif [[ "$mm" -eq 1 ]]; then echo C
  elif [[ "$dnssec" == "true" ]]; then echo A
  else echo B; fi
}

overall_from_rows() {
  awk '
    BEGIN{score=0; n=0}
    {g=$1; n++; if(g=="A")score+=5; else if(g=="B")score+=4; else if(g=="C")score+=3; else if(g=="D")score+=2; else score+=0}
    END{
      avg=(n?score/n:0);
      if(avg>=4.5)print "A";
      else if(avg>=3.5)print "B";
      else if(avg>=2.5)print "C";
      else if(avg>=1.5)print "D";
      else print "F";
    }'
}

host_label="$(jq -r '.host_label // "Unknown Host"' <<<"$input")"
host_id="$(jq -r '.host_id // "unknown"' <<<"$input")"
timestamp="$(jq -r '.timestamp' <<<"$input")"
ts_human="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%Y-%m-%d %H:%M UTC" 2>/dev/null || echo "$timestamp")"

unexpected="$(jq -r '.port_scan.unexpected | length' <<<"$input")"
external_grade="$(grade_external "$unexpected")"
dns_grade="$(grade_dns "$(jq -r '.dns_hijacking.status' <<<"$input")" "$(jq -r '.dns_hijacking.mismatches // 0' <<<"$input")" "$(jq -r '.dns_hijacking.dnssec_validated' <<<"$input")")"
vpn_grade="B"
wg_status="$(jq -r '.wireguard.status' <<<"$input")"
wg_age="$(jq -r '.wireguard.last_handshake_ago_s // 99999' <<<"$input")"
ts_status="$(jq -r '.tailscale.status' <<<"$input")"
if [[ "$wg_status" == "connected" && "$ts_status" == "connected" && "$wg_age" -lt 30 ]]; then vpn_grade="A"
elif [[ "$wg_status" == "connected" && "$ts_status" == "connected" && "$wg_age" -lt 120 ]]; then vpn_grade="B"
elif [[ "$wg_status" == "stale" || "$ts_status" != "connected" ]]; then vpn_grade="C"
elif [[ "$wg_status" == "down" || "$ts_status" == "offline" ]]; then vpn_grade="D"; fi
[[ "$wg_status" == "down" && "$ts_status" != "connected" ]] && vpn_grade="F"

ssh_grade="$(jq -r '.ssh_hardening.grade // "C"' <<<"$input")"
firewall_grade="$(jq -r '.firewall.grade // "C"' <<<"$input")"
tls_grade="A"
tls_status="$(jq -r '.tls.overall_status // "ok"' <<<"$input")"
if [[ "$tls_status" == "expired" ]]; then tls_grade="F"
elif [[ "$tls_status" == "expiring_soon" ]]; then tls_grade="C"; fi
hygiene_grade="$(jq -r '.system_hygiene.grade // "C"' <<<"$input")"
auth_grade="A"
if [[ "$(jq -r '.auth_log.failed_attempts_1h // 0' <<<"$input")" -gt 200 || "$(jq -r '.persistence.new_suid_binaries|length' <<<"$input")" -gt 0 ]]; then
  auth_grade="F"
elif [[ "$(jq -r '.persistence.cron_hash_changed' <<<"$input")" == "true" ]]; then
  auth_grade="D"
elif [[ "$(jq -r '.auth_log.failed_attempts_1h // 0' <<<"$input")" -gt 50 ]]; then
  auth_grade="C"
fi
cve_grade="A"
if [[ "$(jq -r '[.port_scan.service_cves[].matches | length] | add // 0' <<<"$input")" -gt 0 ]]; then
  cve_grade="C"
fi

overall="$(
  printf '%s\n' "$external_grade" "$dns_grade" "$cve_grade" "$vpn_grade" "$ssh_grade" "$firewall_grade" "$tls_grade" "$hygiene_grade" "$auth_grade" | overall_from_rows
)"

cat <<EOF
╔══════════════════════════════════════════════╗
║   NET AUDIT REPORT — $ts_human   ║
║   Host: $host_label ($host_id)            ║
╚══════════════════════════════════════════════╝

OVERALL GRADE: $overall

External Exposure: $external_grade  ($unexpected unexpected open ports)
DNS Integrity: $dns_grade  ($(jq -r '.dns_hijacking.status' <<<"$input"), dnssec=$(jq -r '.dns_hijacking.dnssec_validated' <<<"$input"))
Router/Service CVEs: $cve_grade
VPN Tunnels: $vpn_grade  (WG: $wg_status / TS: $ts_status)
SSH Hardening: $ssh_grade
Firewall: $firewall_grade
TLS Health: $tls_grade  (overall: $tls_status)
System Hygiene: $hygiene_grade
Auth & Persistence: $auth_grade

Internet:  $(jq -r '.internet.status' <<<"$input") ($(jq -r '.internet.latency_ms' <<<"$input")ms, $(jq -r '.internet.packet_loss_pct' <<<"$input")% loss)
WireGuard: $wg_status (handshake: $(jq -r '.wireguard.last_handshake_ago_s // "n/a"' <<<"$input")s ago)
Tailscale: $ts_status | Funnel: $(jq -r '.tailscale.funnel_reachable' <<<"$input")
Home Net:  $(jq -r '.home_network.reachable' <<<"$input") via $(jq -r '.home_network.via' <<<"$input")
EOF

#!/usr/bin/env bash
# report.sh — format net-audit JSON into graded report card
# Usage: bash scripts/report.sh [--format ascii|slack|html|json]  < audit.json
set -euo pipefail

FORMAT="ascii"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="${2:-ascii}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1 (use --format ascii|slack|html|json)" >&2
      exit 2
      ;;
  esac
done

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

# Rubric: suspected→F; any mismatch→D; validated DNSSEC→A; clean + trusted resolvers→B; clean else→C.
grade_dns() {
  local status="$1" mm="$2" dnssec="$3" trusted="$4"
  if [[ "$status" == "suspected" ]]; then echo F
  elif [[ "$mm" -ge 1 ]]; then echo D
  elif [[ "$dnssec" == "true" ]]; then echo A
  elif [[ "$status" == "clean" && "$trusted" == "true" ]]; then echo B
  elif [[ "$status" == "clean" ]]; then echo C
  elif [[ "$trusted" == "true" ]]; then echo B
  else echo C; fi
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

grade_emoji() {
  case "$1" in
    A) echo "🟢" ;;
    B) echo "🟡" ;;
    C) echo "🟠" ;;
    D) echo "🔴" ;;
    *) echo "⛔" ;;
  esac
}

grade_rank() {
  case "$1" in
    A) echo 5 ;;
    B) echo 4 ;;
    C) echo 3 ;;
    D) echo 2 ;;
    *) echo 0 ;;
  esac
}

host_label="$(jq -r '.host_label // "Unknown Host"' <<<"$input")"
host_id="$(jq -r '.host_id // "unknown"' <<<"$input")"
timestamp="$(jq -r '.timestamp' <<<"$input")"
ts_human="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%Y-%m-%d %H:%M UTC" 2>/dev/null || echo "$timestamp")"

unexpected="$(jq -r '.port_scan.unexpected | length' <<<"$input")"
external_grade="$(grade_external "$unexpected")"
dns_trusted="$(jq -r '.dns_hijacking.system_resolver_trusted // false' <<<"$input")"
dns_grade="$(grade_dns "$(jq -r '.dns_hijacking.status' <<<"$input")" "$(jq -r '.dns_hijacking.mismatches // 0' <<<"$input")" "$(jq -r '.dns_hijacking.dnssec_validated' <<<"$input")" "$dns_trusted")"
vpn_grade="B"
wg_status="$(jq -r '.wireguard.status' <<<"$input")"
wg_age="$(jq -r '.wireguard.last_handshake_ago_s // empty' <<<"$input")"
[[ "$wg_age" == "null" || -z "$wg_age" ]] && wg_age="99999"
[[ "$wg_age" =~ ^[0-9]+$ ]] || wg_age="99999"
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

emit_ascii() {
  cat <<EOF
╔══════════════════════════════════════════════╗
║   NET AUDIT REPORT — $ts_human   ║
║   Host: $host_label ($host_id)            ║
╚══════════════════════════════════════════════╝

OVERALL GRADE: $overall

External Exposure: $external_grade  ($unexpected open ports)
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
}

emit_slack() {
  local eg dg cg vg sg fg tg hg ag og line issues=""
  eg="$(grade_emoji "$external_grade")"
  dg="$(grade_emoji "$dns_grade")"
  cg="$(grade_emoji "$cve_grade")"
  vg="$(grade_emoji "$vpn_grade")"
  sg="$(grade_emoji "$ssh_grade")"
  fg="$(grade_emoji "$firewall_grade")"
  tg="$(grade_emoji "$tls_grade")"
  hg="$(grade_emoji "$hygiene_grade")"
  ag="$(grade_emoji "$auth_grade")"
  og="$(grade_emoji "$overall")"
  add_issue() {
    local name="$1" g="$2" emoji="$3"
    [[ "$(grade_rank "$g")" -lt 4 ]] && issues+="- *${name}* ${emoji} (${g})"$'\n'
  }
  add_issue "External Exposure" "$external_grade" "$eg"
  add_issue "DNS Integrity" "$dns_grade" "$dg"
  add_issue "Router/Service CVEs" "$cve_grade" "$cg"
  add_issue "VPN Tunnels" "$vpn_grade" "$vg"
  add_issue "SSH Hardening" "$ssh_grade" "$sg"
  add_issue "Firewall" "$firewall_grade" "$fg"
  add_issue "TLS Health" "$tls_grade" "$tg"
  add_issue "System Hygiene" "$hygiene_grade" "$hg"
  add_issue "Auth & Persistence" "$auth_grade" "$ag"

  line="*Net Audit* ${og} *${overall}* — ${host_label} (\`${host_id}\`) — \`${ts_human}\`"
  printf '%s\n\n' "$line"
  printf '*Summary*\n'
  printf '%s *External Exposure* %s (%s unexpected ports)\n' "$eg" "$external_grade" "$unexpected"
  printf '%s *DNS Integrity* %s (%s, trusted_resolver=%s)\n' "$dg" "$dns_grade" "$(jq -r '.dns_hijacking.status' <<<"$input")" "$(jq -r '.dns_hijacking.system_resolver_trusted' <<<"$input")"
  printf '%s *Router/Service CVEs* %s\n' "$cg" "$cve_grade"
  printf '%s *VPN Tunnels* %s (WG: %s, TS: %s)\n' "$vg" "$vpn_grade" "$wg_status" "$ts_status"
  printf '%s *SSH Hardening* %s\n' "$sg" "$ssh_grade"
  printf '%s *Firewall* %s\n' "$fg" "$firewall_grade"
  printf '%s *TLS Health* %s (%s)\n' "$tg" "$tls_grade" "$tls_status"
  printf '%s *System Hygiene* %s\n' "$hg" "$hygiene_grade"
  printf '%s *Auth & Persistence* %s\n' "$ag" "$auth_grade"
  if [[ -n "$issues" ]]; then
    printf '\n*Issues (below B)*\n%s' "$issues"
  else
    printf '\n*Issues (below B)*\n_No categories below B._\n'
  fi
}

emit_html() {
  cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Net Audit — ${host_id}</title>
<style>
:root { font-family: system-ui, sans-serif; background:#111; color:#e8e8e8; }
body { max-width: 52rem; margin: 0 auto; padding: 1rem; }
header { margin-bottom: 1.25rem; }
h1 { font-size: 1.25rem; margin: 0 0 0.25rem; }
.badge { display:inline-block; padding:0.15rem 0.45rem; border-radius:0.25rem; font-weight:600; font-size:0.85rem; margin-right:0.35rem; }
.gA { background:#1b5e20; color:#e8f5e9; }
.gB { background:#827717; color:#fffde7; }
.gC { background:#e65100; color:#fff3e0; }
.gD { background:#b71c1c; color:#ffebee; }
.gF { background:#212121; color:#ffcdd2; border:1px solid #444; }
details { border:1px solid #333; border-radius:0.35rem; margin:0.5rem 0; padding:0.35rem 0.6rem; background:#1a1a1a; }
summary { cursor:pointer; font-weight:600; }
pre { white-space:pre-wrap; font-size:0.8rem; overflow:auto; background:#0d0d0d; padding:0.5rem; border-radius:0.25rem; }
button#printBtn { margin:0.5rem 0; padding:0.4rem 0.8rem; cursor:pointer; }
@media print { button#printBtn { display:none; } details { border:none; } }
</style>
</head>
<body>
<header>
<h1>Net Audit Report</h1>
<p>${ts_human} — ${host_label} (<code>${host_id}</code>)</p>
<p><span class="badge g${overall}">Overall ${overall}</span></p>
<button type="button" id="printBtn" onclick="window.print()">Print Report</button>
</header>
<section>
<details open><summary><span class="badge g${external_grade}">${external_grade}</span> External Exposure</summary>
<pre>$(jq -c '.port_scan' <<<"$input")</pre></details>
<details open><summary><span class="badge g${dns_grade}">${dns_grade}</span> DNS Integrity</summary>
<pre>$(jq -c '.dns_hijacking' <<<"$input")</pre></details>
<details><summary><span class="badge g${cve_grade}">${cve_grade}</span> Router/Service CVEs</summary>
<pre>$(jq -c '.port_scan.service_cves' <<<"$input")</pre></details>
<details open><summary><span class="badge g${vpn_grade}">${vpn_grade}</span> VPN Tunnels</summary>
<pre>$(jq -c '{wireguard:.wireguard,tailscale:.tailscale,home_network:.home_network}' <<<"$input")</pre></details>
<details open><summary><span class="badge g${ssh_grade}">${ssh_grade}</span> SSH Hardening</summary>
<pre>$(jq -c '.ssh_hardening' <<<"$input")</pre></details>
<details open><summary><span class="badge g${firewall_grade}">${firewall_grade}</span> Firewall</summary>
<pre>$(jq -c '.firewall' <<<"$input")</pre></details>
<details><summary><span class="badge g${tls_grade}">${tls_grade}</span> TLS Health</summary>
<pre>$(jq -c '.tls' <<<"$input")</pre></details>
<details open><summary><span class="badge g${hygiene_grade}">${hygiene_grade}</span> System Hygiene</summary>
<pre>$(jq -c '.system_hygiene' <<<"$input")</pre></details>
<details open><summary><span class="badge g${auth_grade}">${auth_grade}</span> Auth &amp; Persistence</summary>
<pre>$(jq -c '{auth_log:.auth_log,persistence:.persistence}' <<<"$input")</pre></details>
</section>
</body>
</html>
HTML
}

emit_json() {
  jq -n \
    --argjson inp "$input" \
    --arg og "$overall" \
    --arg eg "$external_grade" --arg dg "$dns_grade" --arg cg "$cve_grade" --arg vg "$vpn_grade" \
    --arg sg "$ssh_grade" --arg fg "$firewall_grade" --arg tg "$tls_grade" --arg hg "$hygiene_grade" --arg ag "$auth_grade" \
    '{
      overall_grade:$og,
      timestamp:$inp.timestamp,
      host_id:$inp.host_id,
      categories:[
        {name:"External Exposure",grade:$eg,
          findings:(if ($inp.port_scan.unexpected|length)>0 then ("Unexpected ports: "+($inp.port_scan.unexpected|map(tostring)|join(", "))) else "No unexpected exposed ports." end),
          remediation:"Close unused listeners or expand EXPECTED_OPEN_PORTS after review."},
        {name:"DNS Integrity",grade:$dg,
          findings:($inp.dns_hijacking|tojson),
          remediation:(if ($dg=="F" or $dg=="D") then "Investigate resolver divergence or hijack indicators." else "Prefer trusted resolvers; enable local DNSSEC validation when possible." end)},
        {name:"Router/Service CVEs",grade:$cg,
          findings:(if (($inp.port_scan.service_cves|map(.matches|length)|add)//0)>0 then "CVE matches on scanned services." else "No KEV/CVE hits on scanned banners." end),
          remediation:"Patch or replace affected services; re-run after upgrades."},
        {name:"VPN Tunnels",grade:$vg,
          findings:({wireguard:$inp.wireguard,tailscale:$inp.tailscale,home_network:$inp.home_network}|tojson),
          remediation:"Restore WireGuard/Tailscale paths per runbook; verify handshakes and routes."},
        {name:"SSH Hardening",grade:$sg,
          findings:($inp.ssh_hardening|tojson),
          remediation:"Disable password auth and root login; use non-default port; keep fail2ban active."},
        {name:"Firewall",grade:$fg,
          findings:($inp.firewall|tojson),
          remediation:(if ($inp.firewall.remediation != null) then $inp.firewall.remediation else "Review UFW defaults, IPv6, and Docker/iptables interaction." end)},
        {name:"TLS Health",grade:$tg,
          findings:($inp.tls|tojson),
          remediation:"Renew certificates before expiry; fix broken endpoints."},
        {name:"System Hygiene",grade:$hg,
          findings:($inp.system_hygiene|tojson),
          remediation:"Apply security updates; reboot when kernel/userspace requires it."},
        {name:"Auth & Persistence",grade:$ag,
          findings:({auth_log:$inp.auth_log,persistence:$inp.persistence}|tojson),
          remediation:"Review cron/timer/SUID drift; investigate SSH brute-force spikes."}
      ]
    }'
}

case "$FORMAT" in
  ascii) emit_ascii ;;
  slack) emit_slack ;;
  html) emit_html ;;
  json) emit_json ;;
  *)
    echo "Unknown --format: $FORMAT (use ascii, slack, html, or json)" >&2
    exit 2
    ;;
esac

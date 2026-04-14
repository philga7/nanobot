#!/usr/bin/env bash
# check.sh — NanoBot net-audit master probe
# Usage: bash scripts/check.sh
# Outputs: JSON to stdout
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
CACHE_DIR="$SCRIPT_DIR/../cache"
LAST_SCAN="$CACHE_DIR/last_scan.json"
SUID_BASELINE="$CACHE_DIR/suid_baseline.txt"

mkdir -p "$CACHE_DIR"
touch "$LAST_SCAN" 2>/dev/null || true

json_escape() { jq -Rsa . <<<"${1:-}"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
bool_json() { [[ "$1" == "true" ]] && echo "true" || echo "false"; }

run_ping_stats() {
  local host="$1"
  local out loss avg ok
  if ! out="$(ping -c 3 -W 5 "$host" 2>/dev/null || true)"; then out=""; fi
  loss="$(awk -F',' '/packet loss/{gsub(/%/,"",$3); gsub(/ /,"",$3); print $3}' <<<"$out" | awk '{print int($1)}')"
  avg="$(awk -F'=' '/min\/avg\/max|round-trip/{split($2,a,"/"); gsub(/ /,"",a[2]); print a[2]}' <<<"$out")"
  [[ -z "$loss" ]] && loss=100
  [[ -z "$avg" ]] && avg=null
  [[ "$loss" -lt 100 && "$avg" != "null" ]] && ok=true || ok=false
  jq -nc --arg host "$host" --argjson loss "$loss" --arg avg "$avg" --argjson ok "$ok" \
    '{host:$host,loss_pct:$loss,latency_ms:(if $avg=="null" then null else ($avg|tonumber) end),ok:$ok}'
}

load_prev() {
  if [[ -s "$LAST_SCAN" ]] && jq empty "$LAST_SCAN" >/dev/null 2>&1; then
    jq -c . "$LAST_SCAN"
  else
    echo "{}"
  fi
}

probe_internet() {
  local a b up_count status loss lat dns_ok=false dns_ans
  a="$(run_ping_stats "8.8.8.8")"
  b="$(run_ping_stats "1.1.1.1")"
  up_count=0
  [[ "$(jq -r '.ok' <<<"$a")" == "true" ]] && up_count=$((up_count + 1))
  [[ "$(jq -r '.ok' <<<"$b")" == "true" ]] && up_count=$((up_count + 1))
  loss="$(jq -n --argjson a "$(jq '.loss_pct' <<<"$a")" --argjson c "$(jq '.loss_pct' <<<"$b")" 'if $a>$c then $a else $c end')"
  lat="$(jq -n --argjson x "$(jq '.latency_ms' <<<"$a")" --argjson y "$(jq '.latency_ms' <<<"$b")" \
    'if $x!=null and $y!=null then (($x+$y)/2) elif $x!=null then $x elif $y!=null then $y else null end')"
  status="down"
  if [[ "$up_count" -eq 2 && "$loss" -eq 0 ]]; then
    status="up"
  elif [[ "$up_count" -ge 1 ]]; then
    status="degraded"
  fi
  if has_cmd dig; then
    dns_ans="$(dig +short "$DNS_TEST_DOMAIN" @"8.8.8.8" 2>/dev/null | awk 'NF{print; exit}')"
    [[ -n "$dns_ans" ]] && dns_ok=true
  fi
  jq -nc --arg status "$status" --argjson lat "$lat" --argjson loss "$loss" --arg dns "$([[ "$dns_ok" == true ]] && echo ok || echo fail)" \
    '{status:$status,latency_ms:$lat,packet_loss_pct:$loss,dns:$dns}'
}

probe_wireguard() {
  local prev peer_count=0 prev_peer_count=0 peer_delta=0
  prev="$(load_prev)"
  prev_peer_count="$(jq -r '.wireguard.peer_count // 0' <<<"$prev")"

  if ! has_cmd wg; then
    jq -nc '{interface:"not_found",status:"down",last_handshake_ago_s:null,peer_reachable:false,transfer_down_mb:null,transfer_up_mb:null,psk_configured:false,key_permissions_ok:false,peer_count:0,peer_count_delta:0}'
    return
  fi
  if ! sudo wg show "$WG_INTERFACE" >/dev/null 2>&1; then
    jq -nc '{interface:"not_found",status:"down",last_handshake_ago_s:null,peer_reachable:false,transfer_down_mb:null,transfer_up_mb:null,psk_configured:false,key_permissions_ok:false,peer_count:0,peer_count_delta:0}'
    return
  fi

  local dump line hs now ago status rx tx psk_line psk_ok=false key_perm=false peer_ok=false
  now="$(date +%s)"
  dump="$(sudo wg show "$WG_INTERFACE" dump 2>/dev/null || true)"
  line="$(awk 'NR>1 {print; exit}' <<<"$dump")"
  peer_count="$(sudo wg show "$WG_INTERFACE" peers 2>/dev/null | wc -l | tr -d ' ')"
  peer_delta=$((peer_count - prev_peer_count))

  if [[ -z "$line" ]]; then
    status="down"; ago=null; rx=0; tx=0
  else
    hs="$(awk '{print $5}' <<<"$line")"
    rx="$(awk '{print $6}' <<<"$line")"
    tx="$(awk '{print $7}' <<<"$line")"
    if [[ "${hs:-0}" -le 0 ]]; then
      ago=null; status="down"
    else
      ago=$((now - hs))
      if [[ "$ago" -lt "$WG_STALE_THRESHOLD_S" ]]; then
        status="connected"
      elif [[ "$ago" -le "$WG_DOWN_THRESHOLD_S" ]]; then
        status="stale"
      else
        status="down"
      fi
    fi
  fi
  if [[ "$(jq -r '.ok' <<<"$(run_ping_stats "$WG_PEER_IP")")" == "true" ]]; then peer_ok=true; fi
  psk_line="$(sudo wg show "$WG_INTERFACE" 2>/dev/null | awk -F': ' '/preshared key/{print $2; exit}')"
  [[ -n "$psk_line" && "$psk_line" != "(none)" ]] && psk_ok=true
  local dir_perm key_perm_raw
  dir_perm="$(stat -c '%a' /etc/wireguard 2>/dev/null || echo "")"
  key_perm_raw="$(stat -c '%a' /etc/wireguard/privatekey 2>/dev/null || echo "")"
  [[ "$dir_perm" == "700" && "$key_perm_raw" == "600" ]] && key_perm=true

  jq -nc --arg ifc "$WG_INTERFACE" --arg status "$status" --argjson ago "${ago:-null}" \
    --argjson peer_ok "$peer_ok" --argjson rx "$(awk -v b="${rx:-0}" 'BEGIN{printf "%.2f", b/1024/1024}')" \
    --argjson tx "$(awk -v b="${tx:-0}" 'BEGIN{printf "%.2f", b/1024/1024}')" \
    --argjson psk "$(bool_json "$psk_ok")" --argjson kp "$(bool_json "$key_perm")" \
    --argjson pc "$peer_count" --argjson delta "$peer_delta" \
    '{interface:$ifc,status:$status,last_handshake_ago_s:$ago,peer_reachable:$peer_ok,transfer_down_mb:$rx,transfer_up_mb:$tx,psk_configured:$psk,key_permissions_ok:$kp,peer_count:$pc,peer_count_delta:$delta}'
}

probe_tailscale() {
  if ! has_cmd tailscale; then
    jq -nc '{status:"not_installed",local_ip:null,funnel_reachable:false,home_node_reachable:false}'
    return
  fi
  local status local_ip funnel=false home=false raw backend http
  if ! raw="$(tailscale status --json 2>/dev/null || true)"; then
    jq -nc '{status:"offline",local_ip:null,funnel_reachable:false,home_node_reachable:false}'
    return
  fi
  backend="$(jq -r '.Self.BackendState // ""' <<<"$raw")"
  local_ip="$(jq -r '.Self.TailscaleIPs[0] // empty' <<<"$raw")"
  [[ "$backend" == "Running" ]] && status="connected" || status="offline"
  http="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$TAILSCALE_FUNNEL_URL" || true)"
  [[ "$http" == "200" ]] && funnel=true
  [[ "$(jq -r '.ok' <<<"$(run_ping_stats "$TAILSCALE_HOME_IP")")" == "true" ]] && home=true
  jq -nc --arg st "$status" --arg ip "$local_ip" --argjson funnel "$(bool_json "$funnel")" --argjson home "$(bool_json "$home")" \
    '{status:$st,local_ip:(if $ip=="" then null else $ip end),funnel_reachable:$funnel,home_node_reachable:$home}'
}

probe_home_network() {
  local via="none" reachable=false
  [[ "$(jq -r '.ok' <<<"$(run_ping_stats "$HOME_ROUTER_IP")")" == "true" ]] && reachable=true && via="wireguard"
  if [[ "$reachable" == false && "$(jq -r '.ok' <<<"$(run_ping_stats "$TAILSCALE_HOME_IP")")" == "true" ]]; then
    reachable=true; via="tailscale"
  fi
  jq -nc --argjson r "$(bool_json "$reachable")" --arg via "$via" '{reachable:$r,via:$via}'
}

probe_port_scan() {
  local public_ip nmap_out open_json unexpected_json cve_json
  public_ip="$(curl -s --max-time 5 https://api.ipify.org || true)"
  if ! has_cmd nmap || [[ -z "$public_ip" ]]; then
    jq -nc --arg ip "$public_ip" --argjson exp "$(printf '%s\n' "${EXPECTED_OPEN_PORTS[@]}" | jq -R . | jq -s .)" \
      '{public_ip:(if $ip=="" then null else $ip end),open_ports:[],unexpected:[],expected:$exp,service_cves:[]}'
    return
  fi
  nmap_out="$(nmap -sV -T4 --top-ports 1000 --max-rtt-timeout 5s "$public_ip" 2>/dev/null || true)"
  open_json="$(awk '/^[0-9]+\/tcp/ && /open/{print}' <<<"$nmap_out" | jq -R -s '
    split("\n") | map(select(length>0)) | map(
      capture("(?<port>[0-9]+)/tcp\\s+open\\s+(?<service>\\S+)\\s*(?<version>.*)")
      | {port:(.port|tonumber),service:.service,version:(.version|gsub("^\\s+|\\s+$";"")),state:"open"}
    )')"
  unexpected_json="$(jq -n --argjson opens "$open_json" --argjson exp "$(printf '%s\n' "${EXPECTED_OPEN_PORTS[@]}" | jq -R . | jq -s .)" \
    '$opens | map(select((.port|tostring) as $p | ($exp | index($p) | not))) | map(.port|tostring)')"

  cve_json="$(jq -n '[]')"
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local svc ver cve_matches
    svc="$(jq -r '.service' <<<"$row")"
    ver="$(jq -r '.version' <<<"$row")"
    [[ -z "$svc" || -z "$ver" ]] && continue
    cve_matches="$(bash "$SCRIPT_DIR/cve-lookup.sh" "$svc" "$ver" | jq '.matches // []' 2>/dev/null || echo '[]')"
    cve_json="$(jq -n --argjson cur "$cve_json" --arg svc "$svc" --arg ver "$ver" --argjson m "$cve_matches" \
      '$cur + [{service:$svc,version:$ver,matches:$m}]')"
  done < <(jq -c '.[]' <<<"$open_json")

  jq -nc --arg ip "$public_ip" --argjson open "$open_json" --argjson unexp "$unexpected_json" \
    --argjson exp "$(printf '%s\n' "${EXPECTED_OPEN_PORTS[@]}" | jq -R . | jq -s .)" --argjson sc "$cve_json" \
    '{public_ip:$ip,open_ports:$open,unexpected:$unexp,expected:$exp,service_cves:$sc}'
}

probe_dns_hijacking() {
  if ! has_cmd dig; then
    jq -nc '{status:"unknown",resolvers_checked:0,mismatches:0,details:"dig not installed",dnssec_validated:false}'
    return
  fi
  local checked=0 mismatch_primary=0 mismatch_secondary=0 details="" dnssec=false
  local records_primary=() records_secondary=()
  local resolver ans1 ans2 flags
  for resolver in "${TRUSTED_DNS[@]}"; do
    ans1="$(dig +short "$DNS_TEST_DOMAIN" @"$resolver" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')"
    ans2="$(dig +short "$DNS_TEST_DOMAIN_SECONDARY" @"$resolver" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')"
    [[ -n "$ans1" ]] && records_primary+=("$ans1")
    [[ -n "$ans2" ]] && records_secondary+=("$ans2")
    checked=$((checked + 1))
  done
  if [[ "${#records_primary[@]}" -gt 1 ]]; then
    local first="${records_primary[0]}"
    for r in "${records_primary[@]}"; do [[ "$r" != "$first" ]] && mismatch_primary=$((mismatch_primary + 1)); done
  fi
  if [[ "${#records_secondary[@]}" -gt 1 ]]; then
    local first2="${records_secondary[0]}"
    for r in "${records_secondary[@]}"; do [[ "$r" != "$first2" ]] && mismatch_secondary=$((mismatch_secondary + 1)); done
  fi
  flags="$(dig +dnssec "$DNS_TEST_DOMAIN" @"1.1.1.1" 2>/dev/null | awk '/flags:/{print}')"
  [[ "$flags" == *" ad "* ]] && dnssec=true
  local status="clean" mismatches=0
  mismatches=$((mismatch_primary + mismatch_secondary))
  if [[ "$checked" -eq 0 ]]; then
    status="unknown"
    details="No resolvers responded"
  elif [[ "$mismatch_primary" -gt 0 && "$mismatch_secondary" -gt 0 ]]; then
    status="suspected"
    details="Resolver answer divergence on primary and secondary domains"
  fi
  jq -nc --arg status "$status" --argjson rc "$checked" --argjson mm "$mismatches" --arg details "$details" --argjson dnssec "$(bool_json "$dnssec")" \
    '{status:$status,resolvers_checked:$rc,mismatches:$mm,details:(if $details=="" then null else $details end),dnssec_validated:$dnssec}'
}

probe_ssh_hardening() {
  local cfg root_login="unknown" pass_auth="unknown" pubkey_auth="unknown" port="22" cai=0 cacm=3
  if has_cmd sshd; then
    cfg="$(sudo sshd -T 2>/dev/null || true)"
    root_login="$(awk '/^permitrootlogin /{print $2; exit}' <<<"$cfg")"
    pass_auth="$(awk '/^passwordauthentication /{print $2; exit}' <<<"$cfg")"
    pubkey_auth="$(awk '/^pubkeyauthentication /{print $2; exit}' <<<"$cfg")"
    port="$(awk '/^port /{print $2; exit}' <<<"$cfg")"
    cai="$(awk '/^clientaliveinterval /{print $2; exit}' <<<"$cfg")"
    cacm="$(awk '/^clientalivecountmax /{print $2; exit}' <<<"$cfg")"
  fi
  local fail2ban="not_installed" ufw="not_installed" ak_count=0 ak_hash="sha256:"
  systemctl is-active fail2ban >/dev/null 2>&1 && fail2ban="active" || fail2ban="inactive"
  if has_cmd ufw; then
    ufw="$(ufw status 2>/dev/null | awk 'NR==1{print tolower($2)}')"
    [[ -z "$ufw" ]] && ufw="inactive"
  fi
  if [[ -f /root/.ssh/authorized_keys ]]; then
    ak_count="$(awk 'NF{c++} END{print c+0}' /root/.ssh/authorized_keys 2>/dev/null)"
    ak_hash="sha256:$(sha256sum /root/.ssh/authorized_keys 2>/dev/null | awk '{print $1}')"
  fi
  local grade="C"
  if [[ "$pass_auth" == "no" && "$root_login" == "no" && "$fail2ban" == "active" && "$port" != "22" && "${cai:-0}" -gt 0 ]]; then
    grade="A"
  elif [[ "$pass_auth" == "no" && "$root_login" == "no" && "$fail2ban" == "active" ]]; then
    grade="B"
  elif [[ "$pass_auth" == "yes" && "$root_login" == "yes" && "$fail2ban" == "inactive" ]]; then
    grade="F"
  elif [[ "$pass_auth" == "yes" && "$root_login" == "yes" ]]; then
    grade="D"
  fi
  jq -nc --arg prl "$root_login" --arg pa "$pass_auth" --arg pka "$pubkey_auth" --arg port "$port" \
    --argjson cai "${cai:-0}" --argjson cacm "${cacm:-3}" --arg f2b "$fail2ban" --arg ufw "$ufw" \
    --argjson akc "${ak_count:-0}" --arg akh "$ak_hash" --arg grade "$grade" \
    '{permit_root_login:$prl,password_auth:$pa,pubkey_auth:$pka,port:$port,client_alive_interval:$cai,client_alive_count_max:$cacm,fail2ban:$f2b,ufw_status:$ufw,authorized_key_count:$akc,authorized_key_hash:$akh,grade:$grade}'
}

probe_firewall() {
  if ! has_cmd ufw; then
    jq -nc '{status:"not_installed",default_incoming:"unknown",default_outgoing:"unknown",rules:[],unexpected_allow_rules:[],ipv6_enabled:false,ipv6_ufw_protected:false,docker_running:false,docker_bypass_detected:false,docker_exposed_ports:[],grade:"F"}'
    return
  fi
  local verbose numbered status def_in="unknown" def_out="unknown" ipv6_conf=false ipv6_addr=false docker=false bypass=false
  verbose="$(sudo ufw status verbose 2>/dev/null || true)"
  numbered="$(sudo ufw status numbered 2>/dev/null || true)"
  status="$(awk 'NR==1{print tolower($2)}' <<<"$verbose")"
  [[ "$verbose" == *"Default: deny (incoming)"* ]] && def_in="deny"
  [[ "$verbose" == *"Default: allow (incoming)"* ]] && def_in="allow"
  [[ "$verbose" == *"Default: allow (outgoing)"* ]] && def_out="allow"
  [[ "$verbose" == *"Default: deny (outgoing)"* ]] && def_out="deny"
  [[ "$(grep -E '^IPV6=' /etc/default/ufw 2>/dev/null || true)" == *"yes"* ]] && ipv6_conf=true
  ip -6 addr show scope global 2>/dev/null | awk 'NF{found=1} END{exit !found}' && ipv6_addr=true || true
  systemctl is-active docker >/dev/null 2>&1 && docker=true
  local docker_ports_json='[]'
  if [[ "$docker" == true ]]; then
    docker_ports_json="$(sudo iptables -L DOCKER -n --line-numbers 2>/dev/null | awk '/ACCEPT/ && /0.0.0.0\/0/ {for(i=1;i<=NF;i++) if($i ~ /dpt:/){split($i,a,":"); print a[2]}}' | jq -R . | jq -s 'map(select(length>0)|tonumber) | unique')"
    [[ "$(jq 'length' <<<"$docker_ports_json")" -gt 0 ]] && bypass=true
  fi
  local rules_json unexpected_json
  rules_json="$(awk '
    /^\[/ {next}
    /^[0-9]/ || /^[0-9]+\/(tcp|udp)/ {print}
  ' <<<"$numbered" | jq -R -s '
    split("\n") | map(select(length>0)) | map(
      capture("(?<portproto>[0-9]+(?:/(?:tcp|udp))?)\\s+(?<action>ALLOW|DENY)\\s+IN\\s+(?<from>.*)")?
      // {portproto:"",action:"",from:""}
      | {port:(.portproto|split("/")[0]), protocol:(if (.portproto|contains("/")) then (.portproto|split("/")[1]) else "tcp" end), action:(.action|ascii_downcase), from:.from}
    ) | map(select(.port != ""))
  ')"
  unexpected_json="$(jq -n --argjson rules "$rules_json" --argjson exp "$(printf '%s\n' "${EXPECTED_OPEN_PORTS[@]}" | jq -R . | jq -s .)" \
    '$rules | map(select(.action=="allow" and ((.port|tostring) as $p | ($exp | index($p) | not))))')"
  local grade="C"
  if [[ "$status" != "active" || "$bypass" == true ]]; then grade="F"
  elif [[ "$(jq 'length' <<<"$unexpected_json")" -gt 0 ]]; then grade="D"
  elif [[ "$def_in" == "deny" && "$ipv6_addr" == true && "$ipv6_conf" == true ]]; then grade="A"
  elif [[ "$def_in" == "deny" && "$ipv6_conf" == true ]]; then grade="B"
  fi
  jq -nc --arg status "${status:-inactive}" --arg di "$def_in" --arg do "$def_out" \
    --argjson rules "$rules_json" --argjson un "$unexpected_json" \
    --argjson ipv6_enabled "$(bool_json "$ipv6_addr")" --argjson ipv6_ufw "$(bool_json "$ipv6_conf")" \
    --argjson docker "$(bool_json "$docker")" --argjson bypass "$(bool_json "$bypass")" \
    --argjson dp "$docker_ports_json" --arg grade "$grade" \
    '{status:$status,default_incoming:$di,default_outgoing:$do,rules:$rules,unexpected_allow_rules:$un,ipv6_enabled:$ipv6_enabled,ipv6_ufw_protected:$ipv6_ufw,docker_running:$docker,docker_bypass_detected:$bypass,docker_exposed_ports:$dp,grade:$grade}'
}

probe_tls() {
  local targets_json checks='[]'
  targets_json="$(jq -nc --arg funnel "$TAILSCALE_FUNNEL_URL" '[($funnel|sub("^https?://";"")|split("/")[0])]')"
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    local cert issuer enddate days status
    cert="$(echo | openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null | openssl x509 -noout -enddate -issuer 2>/dev/null || true)"
    if [[ -z "$cert" ]]; then
      checks="$(jq -n --argjson cur "$checks" --arg host "$host" '$cur + [{host:$host,cert_expiry:null,days_until_expiry:null,issuer:null,status:"unreachable"}]')"
      continue
    fi
    enddate="$(awk -F= '/notAfter=/{print $2}' <<<"$cert")"
    issuer="$(awk -F= '/issuer=/{print $2}' <<<"$cert")"
    days="$(python3 - <<'PY' "$enddate"
import sys, datetime
try:
    dt = datetime.datetime.strptime(sys.argv[1], "%b %d %H:%M:%S %Y %Z")
except Exception:
    print(-999); raise SystemExit
print((dt - datetime.datetime.utcnow()).days)
PY
)"
    status="ok"
    [[ "$days" -lt 0 ]] && status="expired"
    [[ "$days" -le "$TLS_WARN_DAYS" ]] && status="expiring_soon"
    [[ "$days" -le "$TLS_CRIT_DAYS" ]] && status="expired"
    checks="$(jq -n --argjson cur "$checks" --arg host "$host" --arg issuer "$issuer" --arg end "$enddate" --argjson d "$days" --arg st "$status" \
      '$cur + [{host:$host,cert_expiry:$end,days_until_expiry:$d,issuer:$issuer,status:$st}]')"
  done < <(jq -r '.[]' <<<"$targets_json")
  local overall="ok"
  jq -e '.[] | select(.status=="expired")' <<<"$checks" >/dev/null 2>&1 && overall="expired"
  if [[ "$overall" == "ok" ]]; then jq -e '.[] | select(.status=="expiring_soon")' <<<"$checks" >/dev/null 2>&1 && overall="expiring_soon"; fi
  jq -nc --argjson checks "$checks" --arg overall "$overall" '{checks:$checks,overall_status:$overall}'
}

probe_auth_log() {
  if ! has_cmd journalctl; then
    jq -nc '{available:false,failed_attempts_1h:0,failed_attempts_24h:0,brute_force_suspected:false,recent_logins:[],unique_source_ips_24h:0}'
    return
  fi
  local f1 f24 unique recent brute=false
  f1="$(journalctl -u ssh --since "1 hour ago" 2>/dev/null | grep -c "Failed" || true)"
  f24="$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep -c "Failed" || true)"
  unique="$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | awk '/Failed/{print $NF}' | sort -u | awk 'NF{c++} END{print c+0}')"
  [[ "${f1:-0}" -gt "$SSH_BRUTE_WARN_THRESHOLD" ]] && brute=true
  recent="$(last -20 2>/dev/null | awk '!/wtmp begins/ {print}' | head -10 | jq -R -s '
    split("\n") | map(select(length>0)) | map(
      capture("^(?<user>\\S+)\\s+(?<terminal>\\S+)\\s+(?<ip>\\S+)\\s+(?<timestamp>.*)$")?
      // {user:"unknown",terminal:"unknown",ip:"unknown",timestamp:.}
    )')"
  jq -nc --argjson f1 "${f1:-0}" --argjson f24 "${f24:-0}" --argjson brute "$(bool_json "$brute")" --argjson recent "$recent" --argjson u "${unique:-0}" \
    '{available:true,failed_attempts_1h:$f1,failed_attempts_24h:$f24,brute_force_suspected:$brute,recent_logins:$recent,unique_source_ips_24h:$u}'
}

probe_outbound() {
  local lines anomalies='[]' count=0
  lines="$(ss -tnp state established 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ "$line" =~ ^State|^Recv-Q|^ESTAB ]] || continue
    [[ "$line" =~ ^ESTAB ]] || continue
    count=$((count + 1))
    local local_addr remote_addr proc rip rport lport trusted=false
    local_addr="$(awk '{print $4}' <<<"$line")"
    remote_addr="$(awk '{print $5}' <<<"$line")"
    proc="$(awk -F'users:\\(\\("' '{if (NF>1){split($2,a,"\""); print a[1]} else print "unknown"}' <<<"$line")"
    rip="${remote_addr%:*}"; rport="${remote_addr##*:}"; lport="${local_addr##*:}"
    [[ "$rip" == 127.* || "$rip" == "::1" || "$rip" == 100.* ]] && continue
    for t in "${TRUSTED_OUTBOUND[@]}"; do [[ "$rip" == "$t" ]] && trusted=true; done
    if [[ "$trusted" == false ]]; then
      anomalies="$(jq -n --argjson cur "$anomalies" --arg lp "$lport" --arg rip "$rip" --arg rp "$rport" --arg proc "$proc" \
        '$cur + [{local_port:($lp|tonumber? // 0),remote_ip:$rip,remote_port:($rp|tonumber? // 0),process:$proc}]')"
    fi
  done <<<"$lines"
  local detected=false
  [[ "$(jq 'length' <<<"$anomalies")" -gt 0 ]] && detected=true
  jq -nc --argjson c "$count" --argjson anomalies "$anomalies" --argjson d "$(bool_json "$detected")" \
    '{established_count:$c,anomalies:$anomalies,anomaly_detected:$d}'
}

probe_persistence() {
  local prev cron_dump cron_hash prev_cron_hash cron_changed=false cron_count timers suid_list suid_hash baseline_hash new_suid='[]' suid_changed=false
  prev="$(load_prev)"
  prev_cron_hash="$(jq -r '.persistence.cron_hash // ""' <<<"$prev")"
  cron_dump="$(
    { cat /etc/crontab 2>/dev/null || true; ls -la /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/ /etc/cron.weekly/ /etc/cron.monthly/ 2>/dev/null || true;
      awk -F: '{print $1}' /etc/passwd 2>/dev/null | while read -r user; do sudo crontab -l -u "$user" 2>/dev/null || true; done; } | sort
  )"
  cron_hash="sha256:$(sha256sum <<<"$cron_dump" | awk '{print $1}')"
  [[ -n "$prev_cron_hash" && "$prev_cron_hash" != "$cron_hash" ]] && cron_changed=true
  cron_count="$(awk 'NF{c++} END{print c+0}' <<<"$cron_dump")"
  timers="$(systemctl list-timers --all --no-pager 2>/dev/null | awk 'NR>1 && NF>=6 {print}' | jq -R -s '
    split("\n") | map(select(length>0)) | map({unit:(split(" ")|map(select(length>0))[5] // "unknown"),next_run:(split(" ")|map(select(length>0))[0] // "n/a"),last_run:(split(" ")|map(select(length>0))[3] // "n/a")})')"
  suid_list="$(sudo find / -xdev -type f -perm -4000 2>/dev/null | sort || true)"
  suid_hash="sha256:$(sha256sum <<<"$suid_list" | awk '{print $1}')"
  if [[ ! -f "$SUID_BASELINE" ]]; then
    printf '%s\n' "$suid_list" >"$SUID_BASELINE"
  else
    baseline_hash="sha256:$(sha256sum "$SUID_BASELINE" 2>/dev/null | awk '{print $1}')"
    [[ "$baseline_hash" != "$suid_hash" ]] && suid_changed=true
    new_suid="$(comm -13 <(sort "$SUID_BASELINE") <(printf '%s\n' "$suid_list" | sort) | jq -R . | jq -s 'map(select(length>0))')"
  fi
  jq -nc --arg ch "$cron_hash" --argjson changed "$(bool_json "$cron_changed")" --argjson count "$cron_count" \
    --argjson timers "$timers" --argjson suids "$(printf '%s\n' "$suid_list" | jq -R . | jq -s 'map(select(length>0))')" \
    --arg sh "$suid_hash" --argjson shc "$(bool_json "$suid_changed")" --argjson ns "$new_suid" \
    '{cron_hash:$ch,cron_hash_changed:$changed,cron_entries_count:$count,systemd_timers:$timers,suid_binaries:$suids,suid_hash:$sh,suid_hash_changed:$shc,new_suid_binaries:$ns}'
}

probe_system_hygiene() {
  local sec total reboot=false pkgs='[]' running installed mismatch=false grade
  sec="$(apt list --upgradable 2>/dev/null | grep -ic security || true)"
  total="$(apt list --upgradable 2>/dev/null | awk 'NR>1{c++} END{print c+0}')"
  if [[ -f /var/run/reboot-required ]]; then
    reboot=true
    pkgs="$(awk 'NF{print}' /var/run/reboot-required.pkgs 2>/dev/null | jq -R . | jq -s 'map(select(length>0))')"
  fi
  running="$(uname -r 2>/dev/null || true)"
  installed="$(dpkg -l "linux-image-*" 2>/dev/null | awk '/^ii/{print $2}' | sort | tail -1)"
  [[ -n "$installed" && "$running" != *"${installed#linux-image-}"* ]] && mismatch=true
  grade="A"
  if [[ "${sec:-0}" -ge 10 && "$mismatch" == true ]]; then grade="F"
  elif [[ "${sec:-0}" -ge 6 || "$mismatch" == true ]]; then grade="D"
  elif [[ "${sec:-0}" -ge 3 || "$reboot" == true ]]; then grade="C"
  elif [[ "${sec:-0}" -ge 1 ]]; then grade="B"
  fi
  jq -nc --argjson sec "${sec:-0}" --argjson total "${total:-0}" --argjson reboot "$(bool_json "$reboot")" \
    --argjson pkgs "$pkgs" --arg run "$running" --arg inst "$installed" --argjson mismatch "$(bool_json "$mismatch")" --arg grade "$grade" \
    '{pending_security_updates:$sec,pending_total_updates:$total,reboot_required:$reboot,reboot_required_packages:$pkgs,running_kernel:$run,installed_kernel:$inst,kernel_mismatch:$mismatch,grade:$grade}'
}

main() {
  local internet wireguard tailscale home port dns ssh firewall tls auth outbound persistence hygiene
  internet="$(probe_internet || echo '{}')"
  wireguard="$(probe_wireguard || echo '{}')"
  tailscale="$(probe_tailscale || echo '{}')"
  home="$(probe_home_network || echo '{}')"
  port="$(probe_port_scan || echo '{}')"
  dns="$(probe_dns_hijacking || echo '{}')"
  ssh="$(probe_ssh_hardening || echo '{}')"
  firewall="$(probe_firewall || echo '{}')"
  tls="$(probe_tls || echo '{}')"
  auth="$(probe_auth_log || echo '{}')"
  outbound="$(probe_outbound || echo '{}')"
  persistence="$(probe_persistence || echo '{}')"
  hygiene="$(probe_system_hygiene || echo '{}')"

  jq -nc \
    --arg schema "1.0" --arg host_id "$HOST_ID" --arg host_label "$HOST_LABEL" --arg ts "$TIMESTAMP" \
    --argjson internet "$internet" --argjson wireguard "$wireguard" --argjson tailscale "$tailscale" \
    --argjson home "$home" --argjson port "$port" --argjson dns "$dns" --argjson ssh "$ssh" \
    --argjson firewall "$firewall" --argjson tls "$tls" --argjson auth "$auth" --argjson outbound "$outbound" \
    --argjson persistence "$persistence" --argjson hygiene "$hygiene" \
    '{schema_version:$schema,host_id:$host_id,host_label:$host_label,timestamp:$ts,internet:$internet,wireguard:$wireguard,tailscale:$tailscale,home_network:$home,port_scan:$port,dns_hijacking:$dns,firewall:$firewall,tls:$tls,ssh_hardening:$ssh,auth_log:$auth,outbound:$outbound,persistence:$persistence,system_hygiene:$hygiene,alert:null}'
}

main | tee "$LAST_SCAN" >/dev/null
jq -c . "$LAST_SCAN"

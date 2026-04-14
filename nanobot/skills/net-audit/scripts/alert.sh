#!/usr/bin/env bash
# alert.sh — evaluate net-audit checks and emit alert JSON
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

CACHE_DIR="$SCRIPT_DIR/../cache"
LAST_ALERT="$CACHE_DIR/last_alert.json"
mkdir -p "$CACHE_DIR"

report_json="$(bash "$SCRIPT_DIR/check.sh")"
now_epoch="$(date +%s)"
dedup_window_s=$((DEDUP_WINDOW_MIN * 60))

sev_rank() {
  case "$1" in
    CRITICAL) echo 4 ;;
    WARNING) echo 3 ;;
    LOW) echo 2 ;;
    INFO) echo 1 ;;
    *) echo 0 ;;
  esac
}

priority_for() {
  case "$1" in
    CRITICAL) echo "max" ;;
    WARNING) echo "high" ;;
    LOW) echo "low" ;;
    INFO) echo "default" ;;
    *) echo "default" ;;
  esac
}

build_alerts() {
  jq -c --argjson warn "$SSH_BRUTE_WARN_THRESHOLD" --argjson crit "$SSH_BRUTE_CRIT_THRESHOLD" '
    . as $r
    | [] as $a
    | (if $r.internet.status == "down" then $a + [{key:"internet_down",severity:"CRITICAL",message:"Internet connectivity is down"}] else $a end) as $a1
    | (if $r.wireguard.status == "down" then $a1 + [{key:"wireguard_down",severity:"CRITICAL",message:"WireGuard tunnel is down"}] else $a1 end) as $a2
    | (if $r.home_network.reachable == false then $a2 + [{key:"home_unreachable",severity:"CRITICAL",message:"Home network is unreachable"}] else $a2 end) as $a3
    | (if $r.dns_hijacking.status == "suspected" then $a3 + [{key:"dns_hijacked",severity:"CRITICAL",message:"DNS hijacking suspected"}] else $a3 end) as $a4
    | (if $r.wireguard.key_permissions_ok == false then $a4 + [{key:"wg_key_exposed",severity:"CRITICAL",message:"WireGuard key permissions are unsafe"}] else $a4 end) as $a5
    | (if ($r.persistence.new_suid_binaries | length) > 0 then $a5 + [{key:"new_suid",severity:"CRITICAL",message:"New SUID binaries detected"}] else $a5 end) as $a6
    | (if $r.auth_log.failed_attempts_1h > $crit then $a6 + [{key:"brute_force_crit",severity:"CRITICAL",message:"Critical SSH brute-force volume detected"}] else $a6 end) as $a7
    | (if $r.tls.overall_status == "expired" then $a7 + [{key:"tls_expired",severity:"CRITICAL",message:"TLS certificate is expired"}] else $a7 end) as $a8
    | (if $r.wireguard.status == "stale" then $a8 + [{key:"wireguard_stale",severity:"WARNING",message:"WireGuard handshake is stale"}] else $a8 end) as $a9
    | (if $r.tailscale.status != "connected" then $a9 + [{key:"tailscale_down",severity:"WARNING",message:"Tailscale is not connected"}] else $a9 end) as $a10
    | (if ($r.port_scan.unexpected | length) > 0 then $a10 + [{key:"unexpected_port",severity:"WARNING",message:"Unexpected open ports detected"}] else $a10 end) as $a11
    | (if $r.firewall.docker_bypass_detected == true then $a11 + [{key:"docker_bypass",severity:"WARNING",message:"Docker bypasses UFW rules"}] else $a11 end) as $a12
    | (if $r.wireguard.peer_count_delta != 0 then $a12 + [{key:"wg_peer_change",severity:"WARNING",message:"WireGuard peer count changed"}] else $a12 end) as $a13
    | (if $r.outbound.anomaly_detected == true then $a13 + [{key:"outbound_anomaly",severity:"WARNING",message:"Unexpected outbound connection detected"}] else $a13 end) as $a14
    | (if $r.persistence.cron_hash_changed == true then $a14 + [{key:"cron_changed",severity:"WARNING",message:"Cron configuration changed"}] else $a14 end) as $a15
    | (if $r.auth_log.failed_attempts_1h > $warn and $r.auth_log.failed_attempts_1h <= $crit then $a15 + [{key:"brute_force_warn",severity:"WARNING",message:"Elevated SSH failed attempts"}] else $a15 end) as $a16
    | (if $r.tls.overall_status == "expiring_soon" then $a16 + [{key:"tls_expiring",severity:"WARNING",message:"TLS certificate expiring soon"}] else $a16 end) as $a17
    | (if $r.system_hygiene.kernel_mismatch == true then $a17 + [{key:"kernel_mismatch",severity:"WARNING",message:"Kernel mismatch detected"}] else $a17 end) as $a18
    | (if $r.firewall.ipv6_ufw_protected == false then $a18 + [{key:"ipv6_exposed",severity:"WARNING",message:"IPv6 is not protected by UFW"}] else $a18 end) as $a19
    | (if $r.tailscale.funnel_reachable == false then $a19 + [{key:"funnel_down",severity:"LOW",message:"Tailscale funnel is unreachable"}] else $a19 end)
  ' <<<"$report_json"
}

alerts="$(build_alerts)"
top="$(jq -r 'sort_by(.severity) | reverse | .[0] // empty | @base64' <<<"$alerts")"

if [[ -z "$top" ]]; then
  if [[ -f "$LAST_ALERT" ]] && jq -e '.key != null' "$LAST_ALERT" >/dev/null 2>&1; then
    jq -nc --argjson report "$report_json" \
      '{alert:{key:"restored",severity:"INFO",priority:"default",title:"Net Audit Restored",message:"All previously active net-audit alerts are cleared."},report:$report}'
    printf '%s\n' '{"key":null,"timestamp":0}' >"$LAST_ALERT"
    exit 0
  fi
  jq -nc --argjson report "$report_json" '{alert:null,report:$report}'
  exit 0
fi

decode() { echo "$1" | base64 --decode; }
top_json="$(decode "$top")"
key="$(jq -r '.key' <<<"$top_json")"
sev="$(jq -r '.severity' <<<"$top_json")"
msg="$(jq -r '.message' <<<"$top_json")"
prio="$(priority_for "$sev")"

if [[ -f "$LAST_ALERT" ]]; then
  last_key="$(jq -r '.key // empty' "$LAST_ALERT" 2>/dev/null || true)"
  last_ts="$(jq -r '.timestamp // 0' "$LAST_ALERT" 2>/dev/null || true)"
  if [[ "$last_key" == "$key" && $((now_epoch - last_ts)) -lt "$dedup_window_s" ]]; then
    jq -nc --argjson report "$report_json" '{alert:null,report:$report}'
    exit 0
  fi
fi

printf '%s\n' "$(jq -nc --arg key "$key" --argjson ts "$now_epoch" '{key:$key,timestamp:$ts}')" >"$LAST_ALERT"

jq -nc --arg key "$key" --arg sev "$sev" --arg prio "$prio" --arg msg "$msg" --arg host "$HOST_ID" --argjson report "$report_json" '
  {
    alert:{
      key:$key,
      severity:$sev,
      priority:$prio,
      title:("Net Audit " + $sev + " (" + $host + ")"),
      message:$msg,
      tags:"net-audit,security"
    },
    report:$report
  }
'

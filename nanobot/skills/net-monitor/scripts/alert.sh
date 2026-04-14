#!/usr/bin/env bash
# Read check.json (path or stdin), evaluate alert rules, POST to ntfy with dedupe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
: "${NET_MONITOR_CACHE_DIR:=$SKILL_ROOT/cache}"
: "${NET_MONITOR_CACHE_FILE:=$NET_MONITOR_CACHE_DIR/last_alert.json}"
: "${NET_MONITOR_NTFY_URL:=}"
: "${NET_MONITOR_DEDUPE_SEC:=1800}"

DRY_RUN=false
DAILY=false
INPUT_PATH=""

usage() {
  echo "Usage: alert.sh [--dry-run] [--daily] <check.json | path-to-json>" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --daily) DAILY=true ;;
    -h | --help) usage ;;
    *)
      [[ -n "$INPUT_PATH" ]] && usage
      INPUT_PATH=$1
      ;;
  esac
  shift
done

read_report() {
  if [[ -n "$INPUT_PATH" ]]; then
    cat "$INPUT_PATH"
  else
    cat
  fi
}

mkdir -p "$NET_MONITOR_CACHE_DIR" "$(dirname "$NET_MONITOR_CACHE_FILE")"

eval_report="$(read_report | jq -c '
  . as $r
  | ($r.internet.status == "down") as $inet_down
  | ($r.wireguard.status == "down" or $r.wireguard.status == "never") as $wg_crit
  | ($r.wireguard.status == "degraded") as $wg_warn
  | ($r.tailscale.status == "disconnected" or $r.tailscale.status == "error") as $ts_bad
  | ($r.tailscale.funnel_reachable == false) as $funnel_bad
  | ($r.internet.status != "down") as $inet_not_down
  | ($inet_not_down and ($r.home_network.reachable == false)) as $home_crit
  | [] as $k0
  | (if $inet_down then $k0 + ["internet_down"] else $k0 end) as $k1
  | (if $home_crit then $k1 + ["home_unreachable"] else $k1 end) as $k2
  | (if ($r.wireguard.status != "absent" and $wg_crit) then $k2 + ["wireguard_down"] else $k2 end) as $k3
  | (if ($r.wireguard.status != "absent" and $wg_warn and ($k3 | contains(["wireguard_down"]) | not)) then $k3 + ["wireguard_stale"] else $k3 end) as $k4
  | (if ($r.tailscale.status != "absent" and $ts_bad) then $k4 + ["tailscale_down"] else $k4 end) as $k5
  | (if ($r.tailscale.funnel_reachable != null and $funnel_bad) then $k5 + ["funnel_down"] else $k5 end) as $keys
  | (if ($keys | index("internet_down")) or ($keys | index("home_unreachable")) or ($keys | index("wireguard_down")) then "CRITICAL"
     elif ($keys | index("tailscale_down")) or ($keys | index("wireguard_stale")) then "WARNING"
     elif ($keys | index("funnel_down")) then "LOW"
     elif ($keys | length) > 0 then "WARNING"
     else "OK" end) as $sev
  | ($keys | sort | join("|")) as $dedupe
  | {
      dedupe_key: (if ($dedupe == "") then "ok" else $dedupe end),
      severity: $sev,
      keys: $keys,
      summary: (
        if ($keys | index("internet_down")) then "VPS has no internet (8.8.8.8 / 1.1.1.1)."
        elif ($keys | index("home_unreachable")) then "Home LAN unreachable while VPS internet is up; likely home ISP or both VPN paths failed."
        elif ($keys | index("wireguard_down")) then "WireGuard tunnel appears down (handshake > 300s or never)."
        elif ($keys | index("tailscale_down")) then "Tailscale is not connected."
        elif ($keys | index("wireguard_stale")) then "WireGuard handshake is stale (> 120s, <= 300s)."
        elif ($keys | index("funnel_down")) then "Tailscale funnel URL did not return 2xx/3xx."
        else "All checks passed." end
      ),
      body: (
        "Internet: \($r.internet.status) loss=\($r.internet.packet_loss_pct)% dns=\($r.internet.dns)\n"
        + "WireGuard: \($r.wireguard.status) hs=\($r.wireguard.last_handshake_ago_s // "n/a")s peer=\($r.wireguard.peer_reachable)\n"
        + "Tailscale: \($r.tailscale.status) funnel=\($r.tailscale.funnel_reachable) home=\($r.tailscale.home_node_reachable)\n"
        + "Home: reachable=\($r.home_network.reachable) via=\($r.home_network.via)"
      )
    }
')"

dedupe_key="$(echo "$eval_report" | jq -r '.dedupe_key')"
severity="$(echo "$eval_report" | jq -r '.severity')"
summary="$(echo "$eval_report" | jq -r '.summary')"
body="$(echo "$eval_report" | jq -r '.body')"

now="$(date +%s)"
send_ntfy() {
  local title=$1 msg=$2 prio=$3
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] ntfy prio=$prio $title"
    echo "$msg" | sed 's/^/  /'
    return 0
  fi
  if [[ -z "$NET_MONITOR_NTFY_URL" ]]; then
    echo "NET_MONITOR_NTFY_URL not set; skip push: $title" >&2
    return 0
  fi
  curl -sS -o /dev/null -w '%{http_code}\n' \
    -H "Title: $title" \
    -H "Priority: $prio" \
    -H "Tags: satellite,skull" \
    --data-binary @- "$NET_MONITOR_NTFY_URL" <<<"$msg" || true
}

priority_for() {
  case "$1" in
    CRITICAL) echo 5 ;;
    WARNING) echo 4 ;;
    INFO) echo 3 ;;
    LOW) echo 2 ;;
    *) echo 3 ;;
  esac
}

should_send() {
  local key=$1
  if [[ "$DAILY" == true ]]; then
    return 0
  fi
  if [[ ! -f "$NET_MONITOR_CACHE_FILE" ]]; then
    return 0
  fi
  local last_key last_at
  last_key="$(jq -r '.last_key // empty' "$NET_MONITOR_CACHE_FILE" 2>/dev/null || true)"
  last_at="$(jq -r '.last_at // 0' "$NET_MONITOR_CACHE_FILE" 2>/dev/null || true)"
  if [[ "$last_key" == "$key" ]]; then
    if [[ "$((now - last_at))" -lt "$NET_MONITOR_DEDUPE_SEC" ]]; then
      return 1
    fi
  fi
  return 0
}

write_cache() {
  local key=$1 sev=$2
  jq -nc --arg k "$key" --arg s "$sev" --argjson t "$now" \
    '{last_key: $k, last_severity: $s, last_at: $t}' >"$NET_MONITOR_CACHE_FILE.tmp"
  mv "$NET_MONITOR_CACHE_FILE.tmp" "$NET_MONITOR_CACHE_FILE"
}

read_cache_state() {
  if [[ ! -f "$NET_MONITOR_CACHE_FILE" ]]; then
    echo "clean"
    return
  fi
  jq -r '.last_severity // "OK"' "$NET_MONITOR_CACHE_FILE" 2>/dev/null || echo "clean"
}

prev_severity="$(read_cache_state)"

if [[ "$DAILY" == true ]]; then
  title="net-monitor daily"
  msg="$(date -u +%Y-%m-%dT%H:%M:%SZ) — $summary"$'\n\n'"$body"
  prio="$(priority_for INFO)"
  send_ntfy "$title" "$msg" "$prio"
  exit 0
fi

if [[ "$severity" == "OK" ]]; then
  if [[ "$prev_severity" != "OK" && "$prev_severity" != "clean" ]]; then
    if should_send "restored"; then
      send_ntfy "Network restored" "Previous issues cleared."$'\n\n'"$body" "$(priority_for INFO)"
      write_cache "restored" "OK"
    fi
  else
    jq -nc --arg k "ok" --arg s "OK" --argjson t "$now" \
      '{last_key: $k, last_severity: $s, last_at: $t}' >"$NET_MONITOR_CACHE_FILE.tmp" 2>/dev/null && \
      mv "$NET_MONITOR_CACHE_FILE.tmp" "$NET_MONITOR_CACHE_FILE" || true
  fi
  exit 0
fi

if ! should_send "$dedupe_key"; then
  echo "Deduped alert ($dedupe_key) within ${NET_MONITOR_DEDUPE_SEC}s" >&2
  exit 0
fi

prio="$(priority_for "$severity")"
title="net-monitor: $severity"
msg="$summary"$'\n\n'"$body"
send_ntfy "$title" "$msg" "$prio"
write_cache "$dedupe_key" "$severity"

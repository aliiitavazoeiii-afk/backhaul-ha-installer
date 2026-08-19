#!/usr/bin/env bash
set -u

VERSION="1.1.0"
DEEP=0
[[ "${1:-}" == "--deep" ]] && DEEP=1

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
BUNDLE="/root/backhaul-ha-secrets.env"
DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || true)"

bundle_get() {
  local key="$1"
  [[ -f "$BUNDLE" ]] || return 0
  sed -n "s/^${key}='\([^']*\)'$/\1/p" "$BUNDLE" | head -n1
}

IRAN_IP="$(bundle_get IRAN_IP)"
FOREIGN_IP="$(bundle_get FOREIGN_IP)"
[[ -n "$DOMAIN" ]] || DOMAIN="$(bundle_get DOMAIN)"
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || { echo "Cannot detect tunnel role." >&2; exit 2; }
[[ "$ROLE" == "iran" ]] && PEER_IP="$FOREIGN_IP" || PEER_IP="$IRAN_IP"

if [[ -t 1 ]]; then
  G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'; B='\033[1m'
else
  G=''; R=''; Y=''; C=''; N=''; B=''
fi

PASS=0; WARN=0; FAIL=0
RESOURCE_BAD=0; NETWORK_BAD=0; PMTU_WARN=0
WSS_HEALTH=-1; TCP_HEALTH=-1; HAPROXY_OK=-1; XRAY_OK=-1; WSS_TLS=-1; TCP_CTRL=-1
WSS_FWD=""; WSS_REV=""; TCP_FWD=""; TCP_REV=""

ok()   { printf "%b[OK]%b   %s\n" "$G" "$N" "$*"; PASS=$((PASS+1)); }
warn() { printf "%b[WARN]%b %s\n" "$Y" "$N" "$*"; WARN=$((WARN+1)); }
fail() { printf "%b[FAIL]%b %s\n" "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
info() { printf "%b[INFO]%b %s\n" "$C" "$N" "$*"; }
section() { printf "\n%b%s%b\n" "$B" "$1" "$N"; }
float_gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
float_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

svc() {
  if systemctl is-active --quiet "$1"; then ok "service $1 active"; else fail "service $1 is NOT active"; fi
}

listener_match() {
  if ss -lntp 2>/dev/null | grep -Eq "$1"; then ok "$2"; return 0; else fail "$2 missing"; return 1; fi
}

health_probe() {
  local label="$1" url="$2" out rc ms
  out="$(curl -sS -o /dev/null --max-time 5 -w '%{http_code} %{time_total}' "$url" 2>/dev/null)"; rc=$?
  if [[ $rc -eq 0 && "${out%% *}" == "200" ]]; then
    ms="$(awk -v t="${out#* }" 'BEGIN{printf "%.0f", t*1000}')"
    ok "$label HTTP 200 (${ms} ms)"
    return 0
  fi
  fail "$label failed (${out:-curl error})"
  return 1
}

read_tcp_counter() {
  local key="$1"
  awk -v k="$key" '
    $1=="Tcp:" && !seen { for(i=2;i<=NF;i++) idx[$i]=i; seen=1; next }
    $1=="Tcp:" && seen { if (idx[k]) print $(idx[k]); exit }
  ' /proc/net/snmp 2>/dev/null
}

section "Tunnel Diagnose v$VERSION"
echo "Role: $ROLE"
echo "Iran: ${IRAN_IP:-unknown}"
echo "Foreign: ${FOREIGN_IP:-unknown}"
echo "Domain: ${DOMAIN:-unknown}"
echo "Peer: ${PEER_IP:-unknown}"

section "1. Local services and listeners"
if [[ "$ROLE" == "iran" ]]; then
  svc backhaul
  svc backhaul-wss
  svc haproxy
  if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then ok "HAProxy config valid"; HAPROXY_OK=1; else fail "HAProxy config invalid"; HAPROXY_OK=0; fi
  listener_match '(:|\])443[[:space:]]' "public HAProxy :443 listening" || true
  listener_match '127\.0\.0\.1:8443' "WSSMux control 127.0.0.1:8443 listening" || true
  listener_match '(:|\])3080[[:space:]]' "TCPMux control :3080 listening" || true
else
  svc backhaul
  svc backhaul-wss
  svc backhaul-health
  if ss -lntp 2>/dev/null | grep -q '127\.0\.0\.1:443'; then ok "Xray listener 127.0.0.1:443 present"; XRAY_OK=1; else fail "Xray listener 127.0.0.1:443 missing"; XRAY_OK=0; fi
  health_probe "local health" "http://127.0.0.1:18090/healthz" || true
fi

section "2. Transport health"
if [[ "$ROLE" == "iran" ]]; then
  if health_probe "WSS end-to-end :10444" "http://127.0.0.1:10444/healthz"; then WSS_HEALTH=1; else WSS_HEALTH=0; fi
  if health_probe "TCP end-to-end :11444" "http://127.0.0.1:11444/healthz"; then TCP_HEALTH=1; else TCP_HEALTH=0; fi
  recent="$(journalctl -u haproxy --since '-10 minutes' --no-pager 2>/dev/null || true)"
  down_count="$(grep -c 'wss_primary is DOWN' <<<"$recent" || true)"
  backup_count="$(grep -c 'vpn_users/tcp_backup' <<<"$recent" || true)"
  [[ "$down_count" -gt 0 ]] && warn "WSS primary marked DOWN $down_count time(s) in last 10m" || ok "no WSS DOWN event in last 10m"
  [[ "$backup_count" -gt 0 ]] && info "HAProxy logged $backup_count TCP-backup session(s) in last 10m"
else
  if timeout 6 openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" -brief </dev/null >/tmp/tunnel-diag-tls.$$ 2>&1; then
    ok "TLS/SNI path to ${DOMAIN}:443 works"; WSS_TLS=1
  else
    fail "TLS/SNI path to ${DOMAIN}:443 failed"; WSS_TLS=0
  fi
  rm -f /tmp/tunnel-diag-tls.$$
  if nc -z -w 4 "$IRAN_IP" 3080 >/dev/null 2>&1; then ok "TCP control ${IRAN_IP}:3080 reachable"; TCP_CTRL=1; else fail "TCP control ${IRAN_IP}:3080 unreachable"; TCP_CTRL=0; fi
  wss_err="$(journalctl -u backhaul-wss --since '-10 minutes' --no-pager 2>/dev/null | grep -Eic 'error|fail|timeout|unexpected EOF|close 1006' || true)"
  tcp_err="$(journalctl -u backhaul --since '-10 minutes' --no-pager 2>/dev/null | grep -Eic 'error|fail|timeout' || true)"
  [[ "$wss_err" -gt 3 ]] && warn "WSS service has $wss_err error-like log lines in last 10m"
  [[ "$tcp_err" -gt 3 ]] && warn "TCP service has $tcp_err error-like log lines in last 10m"
fi

section "3. DNS / certificate / route"
if [[ -n "$DOMAIN" ]]; then
  resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ "$resolved" == "$IRAN_IP" ]]; then ok "$DOMAIN resolves to Iran IP $IRAN_IP"; else fail "$DOMAIN resolves to ${resolved:-nothing}, expected $IRAN_IP"; fi
fi
if [[ "$ROLE" == "iran" && -n "$DOMAIN" && -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
  enddate="$(openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2-)"
  if openssl x509 -checkend 604800 -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" >/dev/null 2>&1; then ok "certificate valid >7 days (expires $enddate)"; else warn "certificate expires within 7 days ($enddate)"; fi
fi
[[ -n "$PEER_IP" ]] && info "route: $(ip route get "$PEER_IP" 2>/dev/null | head -n1)"

section "4. Loss, latency, MTU/PMTU"
PING_OK=0
if command -v ping >/dev/null 2>&1 && [[ -n "$PEER_IP" ]]; then
  p="$(ping -4 -c 5 -W 2 "$PEER_IP" 2>/dev/null || true)"
  loss="$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' <<<"$p" | tail -1)"
  avg="$(awk -F'/' '/^(rtt|round-trip)/{print $5}' <<<"$p" | tail -1)"
  if [[ -n "$avg" ]]; then
    PING_OK=1
    if float_gt "${loss:-100}" 2; then warn "peer ping loss ${loss}% (avg ${avg} ms)"; NETWORK_BAD=1; else ok "peer ping loss ${loss:-0}% (avg ${avg} ms)"; fi
  else
    warn "peer does not return ICMP ping; loss/MTU ICMP tests are limited"
  fi
else
  warn "ping not installed"
fi

iface="$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')"
if [[ -n "$iface" && -r "/sys/class/net/$iface/mtu" ]]; then
  mtu="$(cat "/sys/class/net/$iface/mtu")"; info "default interface $iface MTU=$mtu"
  rxdrop="$(cat "/sys/class/net/$iface/statistics/rx_dropped" 2>/dev/null || echo 0)"; txdrop="$(cat "/sys/class/net/$iface/statistics/tx_dropped" 2>/dev/null || echo 0)"
  rxerr="$(cat "/sys/class/net/$iface/statistics/rx_errors" 2>/dev/null || echo 0)"; txerr="$(cat "/sys/class/net/$iface/statistics/tx_errors" 2>/dev/null || echo 0)"
  if [[ "$rxerr" -gt 0 || "$txerr" -gt 0 ]]; then warn "NIC errors RX=$rxerr TX=$txerr"; NETWORK_BAD=1; else ok "NIC error counters RX=0 TX=0"; fi
  [[ "$rxdrop" -gt 0 || "$txdrop" -gt 0 ]] && info "NIC cumulative drops RX=$rxdrop TX=$txdrop"
fi

if command -v tracepath >/dev/null 2>&1 && [[ -n "$PEER_IP" ]]; then
  tp="$(timeout 8 tracepath -4 -n -m 10 "$PEER_IP" 2>/dev/null || true)"
  pmtu="$(grep -oE 'pmtu [0-9]+' <<<"$tp" | tail -1 | awk '{print $2}')"
  if [[ -n "$pmtu" ]]; then
    if [[ "$pmtu" -lt 1400 ]]; then warn "discovered PMTU=$pmtu (<1400)"; PMTU_WARN=1; else ok "discovered PMTU=$pmtu"; fi
  else
    info "tracepath could not discover peer PMTU"
  fi
else
  info "tracepath unavailable"
fi

if [[ "$PING_OK" -eq 1 ]]; then
  if ping -4 -M do -s 1472 -c 1 -W 2 "$PEER_IP" >/dev/null 2>&1; then
    ok "DF payload 1472 works (1500-byte IPv4 path supported)"
  elif ping -4 -M do -s 1360 -c 1 -W 2 "$PEER_IP" >/dev/null 2>&1; then
    warn "DF 1472 fails but 1360 works: reduced PMTU / fragmentation sensitivity"; PMTU_WARN=1
  else
    warn "DF 1360 also fails while normal ping works: possible PMTU/ICMP filtering issue"; PMTU_WARN=1
  fi
fi

section "5. Server resources"
cpu="$(nproc 2>/dev/null || echo 1)"; load1="$(awk '{print $1}' /proc/loadavg)"
if float_gt "$load1" "$(awk -v c="$cpu" 'BEGIN{print c*2}')"; then warn "high load: $load1 on $cpu CPU(s)"; RESOURCE_BAD=1; else ok "load $load1 on $cpu CPU(s)"; fi
mem_total="$(awk '/MemTotal:/{print $2}' /proc/meminfo)"; mem_avail="$(awk '/MemAvailable:/{print $2}' /proc/meminfo)"
mem_pct="$(awk -v a="$mem_avail" -v t="$mem_total" 'BEGIN{printf "%.1f", a*100/t}')"
if float_lt "$mem_pct" 10; then warn "low available memory: ${mem_pct}%"; RESOURCE_BAD=1; else ok "available memory ${mem_pct}%"; fi
disk_pct="$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
if [[ "$disk_pct" -ge 90 ]]; then warn "root filesystem ${disk_pct}% used"; RESOURCE_BAD=1; else ok "root filesystem ${disk_pct}% used"; fi
if [[ -r /proc/sys/net/netfilter/nf_conntrack_count && -r /proc/sys/net/netfilter/nf_conntrack_max ]]; then
  ct="$(cat /proc/sys/net/netfilter/nf_conntrack_count)"; ctm="$(cat /proc/sys/net/netfilter/nf_conntrack_max)"; ctp="$(awk -v a="$ct" -v b="$ctm" 'BEGIN{printf "%.1f", a*100/b}')"
  if float_gt "$ctp" 80; then warn "conntrack ${ctp}% full ($ct/$ctm)"; RESOURCE_BAD=1; else ok "conntrack ${ctp}% ($ct/$ctm)"; fi
fi
cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"; [[ -n "$cc" ]] && info "TCP congestion control: $cc"
if command -v timedatectl >/dev/null 2>&1; then nts="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"; [[ "$nts" == "yes" ]] && ok "system clock NTP synchronized" || warn "system clock not confirmed NTP-synchronized"; fi

section "6. TCP retransmission sample"
out1="$(read_tcp_counter OutSegs)"; ret1="$(read_tcp_counter RetransSegs)"
if [[ -n "$out1" && -n "$ret1" ]]; then
  sleep 3
  out2="$(read_tcp_counter OutSegs)"; ret2="$(read_tcp_counter RetransSegs)"; dout=$((out2-out1)); dret=$((ret2-ret1))
  if [[ "$dout" -gt 0 ]]; then
    rr="$(awk -v r="$dret" -v o="$dout" 'BEGIN{printf "%.2f", r*100/o}')"
    if float_gt "$rr" 2; then warn "TCP retransmissions high during 3s sample: ${rr}% ($dret/$dout)"; NETWORK_BAD=1; else ok "TCP retransmissions during sample: ${rr}% ($dret/$dout)"; fi
  else
    info "no meaningful TCP traffic during retransmission sample"
  fi
fi

iperf_one() {
  local label="$1" port="$2" reverse="$3" outvar="$4" json rc parsed mbps retrans
  local -a args
  args=(-c 127.0.0.1 -p "$port" -t 4 -O 1 -J)
  [[ "$reverse" == "1" ]] && args+=(-R)
  json="$(timeout 12 iperf3 "${args[@]}" 2>/dev/null)"; rc=$?
  if [[ $rc -ne 0 || -z "$json" ]]; then fail "$label iperf3 failed"; printf -v "$outvar" '%s' ""; return 1; fi
  parsed="$(python3 -c 'import json,sys; d=json.load(sys.stdin); e=d.get("end",{}); r=e.get("sum_received",{}); s=e.get("sum_sent",{}); b=r.get("bits_per_second") or s.get("bits_per_second") or 0; x=s.get("retransmits",0); print(f"{b/1e6:.1f} {x}")' <<<"$json" 2>/dev/null)"
  mbps="${parsed%% *}"; retrans="${parsed#* }"
  if [[ -n "$mbps" ]]; then ok "$label ${mbps} Mbps (retrans ${retrans:-0})"; printf -v "$outvar" '%s' "$mbps"; return 0; fi
  fail "$label parse failed"; printf -v "$outvar" '%s' ""; return 1
}

if [[ "$DEEP" -eq 1 ]]; then
  section "7. Deep transport throughput"
  if [[ "$ROLE" != "iran" ]]; then
    info "Deep WSS-vs-TCP throughput is run from the Iran server."
  elif ! command -v iperf3 >/dev/null 2>&1; then
    warn "iperf3 missing; run enable-diagnostics.sh once on both servers"
  else
    if nc -z -w 2 127.0.0.1 10445 >/dev/null 2>&1; then
      iperf_one 'WSS Iran -> Foreign' 10445 0 WSS_FWD || true
      iperf_one 'WSS Foreign -> Iran' 10445 1 WSS_REV || true
    else
      warn "WSS diagnostic port :10445 unavailable"
    fi
    if nc -z -w 2 127.0.0.1 11445 >/dev/null 2>&1; then
      iperf_one 'TCP Iran -> Foreign' 11445 0 TCP_FWD || true
      iperf_one 'TCP Foreign -> Iran' 11445 1 TCP_REV || true
    else
      warn "TCP diagnostic port :11445 unavailable"
    fi
  fi
fi

section "Diagnosis"
if [[ "$ROLE" == "foreign" ]]; then
  if [[ "$XRAY_OK" -eq 0 ]]; then
    fail "LIKELY ROOT CAUSE: Xray/3x-ui is not listening on 127.0.0.1:443."
  elif [[ "$WSS_TLS" -eq 0 && "$TCP_CTRL" -eq 1 ]]; then
    warn "LIKELY: WSS/443/SNI path problem. Possible filtering, HAProxy/WSS failure, or TLS/DNS issue; TCP control is still reachable."
  elif [[ "$WSS_TLS" -eq 1 && "$TCP_CTRL" -eq 0 ]]; then
    warn "LIKELY: TCPMux :3080 path/firewall issue; WSS path is reachable."
  elif [[ "$WSS_TLS" -eq 0 && "$TCP_CTRL" -eq 0 ]]; then
    fail "LIKELY: broader path/firewall/Iran-server reachability issue; both WSS and TCP control probes failed."
  elif [[ "$RESOURCE_BAD" -eq 1 ]]; then
    warn "LIKELY: local resource pressure may be affecting tunnel performance."
  elif [[ "$NETWORK_BAD" -eq 1 || "$PMTU_WARN" -eq 1 ]]; then
    warn "LIKELY: network path quality / retransmission / PMTU issue rather than a dead tunnel service."
  else
    ok "Foreign-side core checks look healthy."
  fi
else
  if [[ "$HAPROXY_OK" -eq 0 ]]; then
    fail "LIKELY ROOT CAUSE: HAProxy config/service problem on Iran."
  elif [[ "$WSS_HEALTH" -eq 0 && "$TCP_HEALTH" -eq 1 ]]; then
    warn "LIKELY: WSS primary is unavailable; HAProxy should fail over to TCP backup. Possible WSS failure or 443/SNI path filtering."
  elif [[ "$WSS_HEALTH" -eq 1 && "$TCP_HEALTH" -eq 0 ]]; then
    warn "LIKELY: TCP backup is unavailable. VPN can still work on WSS but redundancy is lost."
  elif [[ "$WSS_HEALTH" -eq 0 && "$TCP_HEALTH" -eq 0 ]]; then
    fail "LIKELY: Foreign/Xray/client services or the Iran<->Foreign path is broken; both end-to-end transports failed."
  elif [[ "$RESOURCE_BAD" -eq 1 ]]; then
    warn "LIKELY: Iran server resource pressure may be limiting performance."
  elif [[ "$NETWORK_BAD" -eq 1 || "$PMTU_WARN" -eq 1 ]]; then
    warn "LIKELY: path loss/retransmission/PMTU problem. Both tunnel health checks may still be green while speed suffers."
  elif [[ "$DEEP" -eq 1 && -n "$WSS_FWD" && -n "$TCP_FWD" ]]; then
    if awk -v w="$WSS_FWD" -v t="$TCP_FWD" 'BEGIN{exit !(w < t*0.55)}'; then
      warn "LIKELY: WSS-specific performance degradation; TCP throughput is materially higher."
    elif awk -v w="$TCP_FWD" -v t="$WSS_FWD" 'BEGIN{exit !(w < t*0.55)}'; then
      warn "LIKELY: TCPMux-specific performance degradation; WSS throughput is materially higher."
    else
      ok "WSS and TCP tunnel throughput are in the same general range."
    fi
  else
    ok "Tunnel core looks healthy. If end-user VPN is still slow, investigate Xray/user ISP/client path next."
  fi
fi

printf "\nSummary: %b%d OK%b, %b%d WARN%b, %b%d FAIL%b\n" "$G" "$PASS" "$N" "$Y" "$WARN" "$N" "$R" "$FAIL" "$N"
[[ "$FAIL" -gt 0 ]] && exit 2
[[ "$WARN" -gt 0 ]] && exit 1
exit 0

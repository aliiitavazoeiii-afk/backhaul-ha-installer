#!/usr/bin/env bash
set -u
VERSION="1.3.0"
DEEP=0
REPAIR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep) DEEP=1 ;;
    --repair) REPAIR=1 ;;
    -h|--help)
      cat <<'H'
Usage: tunnel-diagnose [--deep] [--repair]
  --deep    compare WSSMux, TCPMux and plain TCP throughput (run on Iran)
  --repair  restart only a transport whose control path is reachable but data-plane is stale
H
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
BUNDLE=/root/backhaul-ha-secrets.env
getv(){ sed -n "s/^$1='\([^']*\)'$/\1/p" "$BUNDLE" 2>/dev/null | head -1; }
IRAN_IP="$(getv IRAN_IP)"; FOREIGN_IP="$(getv FOREIGN_IP)"; DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || getv DOMAIN)"
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo "Tunnel role not found." >&2; exit 2; }
[[ "$ROLE" == iran ]] && PEER="$FOREIGN_IP" || PEER="$IRAN_IP"

if [[ -t 1 ]]; then G='\033[0;32m';R='\033[0;31m';Y='\033[1;33m';C='\033[0;36m';N='\033[0m'; else G=;R=;Y=;C=;N=; fi
P=0; W=0; F=0; NET=0; RES=0; MTU=0
WSS=-1; TCPMUX=-1; PLAIN=-1; TLS=-1; C3080=-1; C3081=-1; XR=-1
WSS_REC=-1; TCPMUX_REC=-1; PLAIN_REC=-1
WF=; WR=; TF=; TR=; PF=; PR=
ok(){ printf '%b[OK]%b   %s\n' "$G" "$N" "$*"; P=$((P+1)); }
warn(){ printf '%b[WARN]%b %s\n' "$Y" "$N" "$*"; W=$((W+1)); }
fail(){ printf '%b[FAIL]%b %s\n' "$R" "$N" "$*"; F=$((F+1)); }
info(){ printf '%b[INFO]%b %s\n' "$C" "$N" "$*"; }
sec(){ printf '\n%s\n' "$1"; }
svc(){ systemctl is-active --quiet "$1" && ok "service $1 active" || fail "service $1 NOT active"; }
health(){ local out; out="$(curl -sS -o /dev/null --max-time 5 -w '%{http_code} %{time_total}' "$2" 2>/dev/null)"; if [[ "${out%% *}" == 200 ]]; then ok "$1 HTTP 200 ($(awk -v t="${out#* }" 'BEGIN{printf "%.0f",t*1000}') ms)"; return 0; else fail "$1 failed (${out:-curl error})"; return 1; fi; }
recent(){ journalctl -u "$1" --since '-120 seconds' --no-pager 2>/dev/null | grep -q "$2"; }
fg(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }

iperf_one(){
  local label="$1" port="$2" reverse="$3" outvar="$4" json parsed
  local -a args=(-c 127.0.0.1 -p "$port" -t 4 -O 1 -J)
  [[ "$reverse" == 1 ]] && args+=(-R)
  json="$(timeout 12 iperf3 "${args[@]}" 2>/dev/null)" || { fail "$label iperf3 failed"; return 1; }
  parsed="$(python3 -c 'import json,sys; d=json.load(sys.stdin); e=d.get("end",{}); s=e.get("sum_received") or e.get("sum_sent") or {}; print("%.1f"%(s.get("bits_per_second",0)/1e6))' <<<"$json" 2>/dev/null)"
  [[ -n "$parsed" ]] || { fail "$label parse failed"; return 1; }
  ok "$label $parsed Mbps"
  printf -v "$outvar" '%s' "$parsed"
}

sec "Tunnel Diagnose v$VERSION"
echo "Role: $ROLE"
echo "Iran: $IRAN_IP"
echo "Foreign: $FOREIGN_IP"
echo "Domain: $DOMAIN"
echo "Peer: $PEER"

sec '1. Local services and listeners'
if [[ "$ROLE" == iran ]]; then
  svc backhaul; svc backhaul-wss; svc backhaul-tcp; svc haproxy
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 && ok 'HAProxy config valid' || fail 'HAProxy config invalid'
  ss -lntp 2>/dev/null | grep -q ':443 ' && ok 'public HAProxy :443 listening' || fail 'public HAProxy :443 missing'
  ss -lntp 2>/dev/null | grep -q '127.0.0.1:8443' && ok 'WSSMux control :8443 listening' || fail 'WSSMux control :8443 missing'
  ss -lntp 2>/dev/null | grep -q ':3080 ' && ok 'TCPMux control :3080 listening' || fail 'TCPMux control :3080 missing'
  ss -lntp 2>/dev/null | grep -q ':3081 ' && ok 'plain TCP control :3081 listening' || fail 'plain TCP control :3081 missing'
else
  svc backhaul; svc backhaul-wss; svc backhaul-tcp; svc backhaul-health
  ss -lntp 2>/dev/null | grep -q '127.0.0.1:443' && { ok 'Xray listener 127.0.0.1:443 present'; XR=1; } || { fail 'Xray listener 127.0.0.1:443 missing'; XR=0; }
  health 'local health' http://127.0.0.1:18090/healthz || true
fi

sec '2. Transport health'
if [[ "$ROLE" == iran ]]; then
  health 'WSSMux end-to-end :10444' http://127.0.0.1:10444/healthz && WSS=1 || WSS=0
  health 'TCPMux end-to-end :11444' http://127.0.0.1:11444/healthz && TCPMUX=1 || TCPMUX=0
  health 'plain TCP end-to-end :12444' http://127.0.0.1:12444/healthz && PLAIN=1 || PLAIN=0
  if ((WSS==1)); then info 'HAProxy preferred path: WSSMux'; elif ((TCPMUX==1)); then info 'HAProxy preferred path: TCPMux backup'; elif ((PLAIN==1)); then info 'HAProxy preferred path: plain TCP emergency backup'; else info 'HAProxy preferred path: NONE'; fi
else
  timeout 6 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -brief </dev/null >/dev/null 2>&1 && { ok 'TLS/SNI WSS path reachable'; TLS=1; } || { fail 'TLS/SNI WSS path failed'; TLS=0; }
  nc -z -w 4 "$IRAN_IP" 3080 >/dev/null 2>&1 && { ok 'TCPMux :3080 reachable'; C3080=1; } || { fail 'TCPMux :3080 unreachable'; C3080=0; }
  nc -z -w 4 "$IRAN_IP" 3081 >/dev/null 2>&1 && { ok 'plain TCP :3081 reachable'; C3081=1; } || { fail 'plain TCP :3081 unreachable'; C3081=0; }
  recent backhaul-wss 'connected to local address 127.0.0.1:18090 successfully' && { ok 'WSSMux data-plane health traffic recent'; WSS_REC=1; } || { warn 'WSSMux data-plane health traffic absent for 120s'; WSS_REC=0; }
  recent backhaul 'connected to local address 127.0.0.1:18090 successfully' && { ok 'TCPMux data-plane health traffic recent'; TCPMUX_REC=1; } || { warn 'TCPMux data-plane health traffic absent for 120s'; TCPMUX_REC=0; }
  recent backhaul-tcp 'connected to local address 127.0.0.1:18090 successfully' && { ok 'plain TCP data-plane health traffic recent'; PLAIN_REC=1; } || { warn 'plain TCP data-plane health traffic absent for 120s'; PLAIN_REC=0; }
fi

sec '3. DNS / route / certificate'
r="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
[[ "$r" == "$IRAN_IP" ]] && ok "$DOMAIN -> $IRAN_IP" || fail "$DOMAIN -> ${r:-none}, expected $IRAN_IP"
info "route: $(ip route get "$PEER" 2>/dev/null | head -1)"
if [[ "$ROLE" == iran && -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then openssl x509 -checkend 604800 -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" >/dev/null 2>&1 && ok 'certificate valid >7 days' || warn 'certificate expires within 7 days'; fi

sec '4. Loss / MTU / PMTU'
p="$(ping -4 -c 5 -W 2 "$PEER" 2>/dev/null || true)"; loss="$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' <<<"$p" | tail -1)"; avg="$(awk -F/ '/^(rtt|round-trip)/{print $5}' <<<"$p" | tail -1)"
if [[ -n "$avg" ]]; then fg "${loss:-100}" 2 && { warn "peer loss ${loss}% avg ${avg} ms"; NET=1; } || ok "peer loss ${loss:-0}% avg ${avg} ms"; else info 'peer ICMP unavailable'; fi
iface="$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')"; [[ -n "$iface" ]] && info "interface $iface MTU=$(cat /sys/class/net/$iface/mtu 2>/dev/null || echo '?')"
if [[ -n "$avg" ]]; then ping -4 -M do -s 1472 -c 1 -W 2 "$PEER" >/dev/null 2>&1 && ok 'DF 1472 works (IPv4 MTU 1500)' || { ping -4 -M do -s 1360 -c 1 -W 2 "$PEER" >/dev/null 2>&1 && warn 'DF 1472 fails; 1360 works' || warn 'DF 1360 also fails'; MTU=1; }; fi

sec '5. Server resources / retransmission'
cpu="$(nproc 2>/dev/null || echo 1)"; load="$(awk '{print $1}' /proc/loadavg)"; fg "$load" "$(awk -v c="$cpu" 'BEGIN{print c*2}')" && { warn "high load $load/$cpu"; RES=1; } || ok "load $load on $cpu CPU(s)"
mt="$(awk '/MemTotal/{print $2}' /proc/meminfo)"; ma="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"; mp="$(awk -v a="$ma" -v t="$mt" 'BEGIN{printf "%.1f",a*100/t}')"; fg 10 "$mp" && { warn "memory available ${mp}%"; RES=1; } || ok "memory available ${mp}%"
du="$(df -P / | awk 'NR==2{gsub(/%/,"",$5);print $5}')"; ((du>=90)) && { warn "disk ${du}% used"; RES=1; } || ok "disk ${du}% used"
readc(){ awk -v k="$1" '$1=="Tcp:"&&!s{for(i=2;i<=NF;i++)x[$i]=i;s=1;next}$1=="Tcp:"&&s{print $(x[k]);exit}' /proc/net/snmp; }
o1="$(readc OutSegs)"; q1="$(readc RetransSegs)"; sleep 3; o2="$(readc OutSegs)"; q2="$(readc RetransSegs)"; dout=$((o2-o1)); dret=$((q2-q1))
if ((dout>=100)); then rp="$(awk -v r="$dret" -v o="$dout" 'BEGIN{printf "%.2f",r*100/o}')"; fg "$rp" 2 && { warn "TCP retrans ${rp}% ($dret/$dout)"; NET=1; } || ok "TCP retrans ${rp}% ($dret/$dout)"; else info "TCP retrans sample too small ($dout outbound segments)"; fi

if ((DEEP)); then
  sec '6. Deep throughput'
  if [[ "$ROLE" != iran ]]; then info 'Run --deep on Iran.'; elif ! command -v iperf3 >/dev/null 2>&1; then warn 'iperf3 missing'; else
    nc -z -w2 127.0.0.1 10445 >/dev/null 2>&1 && { iperf_one 'WSSMux Iran -> Foreign' 10445 0 WF || true; iperf_one 'WSSMux Foreign -> Iran' 10445 1 WR || true; } || warn 'WSSMux diagnostic endpoint unavailable'
    nc -z -w2 127.0.0.1 11445 >/dev/null 2>&1 && { iperf_one 'TCPMux Iran -> Foreign' 11445 0 TF || true; iperf_one 'TCPMux Foreign -> Iran' 11445 1 TR || true; } || warn 'TCPMux diagnostic endpoint unavailable'
    nc -z -w2 127.0.0.1 12445 >/dev/null 2>&1 && { iperf_one 'plain TCP Iran -> Foreign' 12445 0 PF || true; iperf_one 'plain TCP Foreign -> Iran' 12445 1 PR || true; } || warn 'plain TCP diagnostic endpoint unavailable'
  fi
fi

sec 'Diagnosis'
if [[ "$ROLE" == iran ]]; then
  healthy=$(( (WSS==1) + (TCPMUX==1) + (PLAIN==1) ))
  if ((healthy==3)); then ok 'All three transports healthy; HAProxy will prefer WSSMux.'
  elif ((healthy==2)); then warn 'One transport is down; HAProxy still has two usable paths.'
  elif ((healthy==1)); then warn 'Only one transport is healthy; VPN can work but redundancy is degraded.'
  else fail 'All three end-to-end transports are down.'; fi
else
  if ((XR==0)); then fail 'LIKELY ROOT CAUSE: Xray is not listening on 127.0.0.1:443.'
  elif ((PLAIN_REC==1 && WSS_REC==0 && TCPMUX_REC==0)); then warn 'LIKELY: multiplexed transports are stalled/filtered while plain TCP remains healthy.'
  elif ((WSS_REC==1 && TCPMUX_REC==0 && PLAIN_REC==0)); then warn 'Only WSSMux data-plane is healthy.'
  elif ((TCPMUX_REC==1 && WSS_REC==0 && PLAIN_REC==0)); then warn 'Only TCPMux data-plane is healthy.'
  elif ((PLAIN_REC==1 && (WSS_REC==1 || TCPMUX_REC==1))); then ok 'At least two transport data-planes are active.'
  elif ((WSS_REC==0 && TCPMUX_REC==0 && PLAIN_REC==0)); then fail 'No transport has recent end-to-end health traffic.'
  elif ((RES)); then warn 'LIKELY: local resource pressure.'
  elif ((NET||MTU)); then warn 'LIKELY: route/retransmission/PMTU issue.'
  else ok 'Foreign-side core checks look healthy.'; fi
fi

if ((REPAIR)); then
  sec 'Repair'
  if [[ "$ROLE" == foreign ]]; then
    repaired=0
    if ((TLS==1 && WSS_REC==0)) && systemctl is-active --quiet backhaul-wss; then warn 'Restarting stalled WSSMux client only.'; systemctl restart backhaul-wss; repaired=1; fi
    if ((C3080==1 && TCPMUX_REC==0)) && systemctl is-active --quiet backhaul; then warn 'Restarting stalled TCPMux client only.'; systemctl restart backhaul; repaired=1; fi
    if ((C3081==1 && PLAIN_REC==0)) && systemctl is-active --quiet backhaul-tcp; then warn 'Restarting stalled plain TCP client only.'; systemctl restart backhaul-tcp; repaired=1; fi
    ((repaired)) && { sleep 7; ok 'Targeted transport restart completed; run tunnel-diagnose again.'; } || info 'No safe targeted repair pattern matched.'
  else
    info 'Run --repair on Foreign for client-side transport stalls; HAProxy already fails over automatically on Iran.'
  fi
fi

printf '\nSummary: %b%d OK%b, %b%d WARN%b, %b%d FAIL%b\n' "$G" "$P" "$N" "$Y" "$W" "$N" "$R" "$F" "$N"
((F>0)) && exit 2
((W>0)) && exit 1
exit 0

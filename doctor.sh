#!/usr/bin/env bash
set -u
VERSION="1.2.0"; DEEP=0; REPAIR=0
while [[ $# -gt 0 ]]; do case "$1" in --deep) DEEP=1;; --repair) REPAIR=1;; -h|--help) echo 'Usage: tunnel-diagnose [--deep] [--repair]'; exit 0;; *) echo "Unknown option: $1" >&2; exit 2;; esac; shift; done
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"; B=/root/backhaul-ha-secrets.env
getv(){ sed -n "s/^$1='\([^']*\)'$/\1/p" "$B" 2>/dev/null | head -1; }
IRAN_IP="$(getv IRAN_IP)"; FOREIGN_IP="$(getv FOREIGN_IP)"; DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || getv DOMAIN)"
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo 'Tunnel role not found.' >&2; exit 2; }
[[ "$ROLE" == iran ]] && PEER="$FOREIGN_IP" || PEER="$IRAN_IP"
if [[ -t 1 ]]; then G='\033[0;32m';R='\033[0;31m';Y='\033[1;33m';C='\033[0;36m';N='\033[0m'; else G=;R=;Y=;C=;N=; fi
P=0;W=0;F=0; NET=0; RES=0; MTU=0; WH=-1;TH=-1;HT=-1;XR=-1;WT=-1;TC=-1;WR=-1;TR=-1
ok(){ printf '%b[OK]%b   %s\n' "$G" "$N" "$*"; P=$((P+1)); }; warn(){ printf '%b[WARN]%b %s\n' "$Y" "$N" "$*"; W=$((W+1)); }; fail(){ printf '%b[FAIL]%b %s\n' "$R" "$N" "$*"; F=$((F+1)); }; info(){ printf '%b[INFO]%b %s\n' "$C" "$N" "$*"; }; sec(){ printf '\n%s\n' "$1"; }
active(){ systemctl is-active --quiet "$1"; }; svc(){ active "$1" && ok "service $1 active" || fail "service $1 NOT active"; }
health(){ local x; x="$(curl -sS -o /dev/null --max-time 5 -w '%{http_code} %{time_total}' "$2" 2>/dev/null)"; [[ "${x%% *}" == 200 ]] && { ok "$1 HTTP 200 ($(awk -v t="${x#* }" 'BEGIN{printf "%.0f",t*1000}') ms)"; return 0; }; fail "$1 failed (${x:-curl error})"; return 1; }
recent(){ journalctl -u "$1" --since '-120 seconds' --no-pager 2>/dev/null | grep -q "$2"; }
fg(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
iperf(){ local j p; j="$(timeout 12 iperf3 -c 127.0.0.1 -p "$2" -t 4 -O 1 -J ${3:+-R} 2>/dev/null)" || { fail "$1 iperf3 failed"; return; }; p="$(python3 -c 'import json,sys;d=json.load(sys.stdin);e=d["end"];s=e.get("sum_received") or e.get("sum_sent") or {};print("%.1f"%(s.get("bits_per_second",0)/1e6))' <<<"$j" 2>/dev/null)"; [[ -n "$p" ]] && { ok "$1 $p Mbps"; printf -v "$4" '%s' "$p"; } || fail "$1 parse failed"; }
sec "Tunnel Diagnose v$VERSION"; echo "Role: $ROLE"; echo "Iran: $IRAN_IP"; echo "Foreign: $FOREIGN_IP"; echo "Domain: $DOMAIN"; echo "Peer: $PEER"
sec '1. Local services and listeners'
if [[ "$ROLE" == iran ]]; then
  svc backhaul; svc backhaul-wss; svc haproxy
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 && { ok 'HAProxy config valid'; HT=1; } || { fail 'HAProxy config invalid'; HT=0; }
  ss -lntp 2>/dev/null | grep -q ':443 ' && ok 'public HAProxy :443 listening' || fail 'public HAProxy :443 missing'
  ss -lntp 2>/dev/null | grep -q '127.0.0.1:8443' && ok 'WSSMux control :8443 listening' || fail 'WSSMux control :8443 missing'
  ss -lntp 2>/dev/null | grep -q ':3080 ' && ok 'TCPMux control :3080 listening' || fail 'TCPMux control :3080 missing'
else
  svc backhaul; svc backhaul-wss; svc backhaul-health
  ss -lntp 2>/dev/null | grep -q '127.0.0.1:443' && { ok 'Xray listener 127.0.0.1:443 present'; XR=1; } || { fail 'Xray listener 127.0.0.1:443 missing'; XR=0; }
  health 'local health' http://127.0.0.1:18090/healthz || true
fi
sec '2. Transport health'
if [[ "$ROLE" == iran ]]; then
  health 'WSS end-to-end :10444' http://127.0.0.1:10444/healthz && WH=1 || WH=0
  health 'TCP end-to-end :11444' http://127.0.0.1:11444/healthz && TH=1 || TH=0
  h="$(journalctl -u haproxy --since '-10 minutes' --no-pager 2>/dev/null || true)"; d="$(grep -c 'wss_primary is DOWN' <<<"$h" || true)"; b="$(grep -c 'vpn_users/tcp_backup' <<<"$h" || true)"
  ((d>0)) && warn "WSS primary marked DOWN $d time(s) in last 10m" || ok 'no WSS DOWN event in last 10m'; ((b>0)) && info "HAProxy logged $b TCP-backup session(s)"
else
  timeout 6 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -brief </dev/null >/dev/null 2>&1 && { ok 'TLS/SNI WSS path reachable'; WT=1; } || { fail 'TLS/SNI WSS path failed'; WT=0; }
  nc -z -w 4 "$IRAN_IP" 3080 >/dev/null 2>&1 && { ok 'TCPMux :3080 reachable'; TC=1; } || { fail 'TCPMux :3080 unreachable'; TC=0; }
  recent backhaul-wss 'connected to local address 127.0.0.1:18090 successfully' && { ok 'WSS data-plane health traffic recent'; WR=1; } || { warn 'WSS data-plane health traffic absent for 120s'; WR=0; }
  recent backhaul-wss 'heartbeat received successfully' && ok 'WSS heartbeat recent' || warn 'WSS heartbeat absent for 120s'
  recent backhaul 'connected to local address 127.0.0.1:18090 successfully' && { ok 'TCP data-plane health traffic recent'; TR=1; } || { warn 'TCP data-plane health traffic absent for 120s'; TR=0; }
fi
sec '3. DNS / route / certificate'
r="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"; [[ "$r" == "$IRAN_IP" ]] && ok "$DOMAIN -> $IRAN_IP" || fail "$DOMAIN -> ${r:-none}, expected $IRAN_IP"
info "route: $(ip route get "$PEER" 2>/dev/null | head -1)"
if [[ "$ROLE" == iran && -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then openssl x509 -checkend 604800 -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" >/dev/null 2>&1 && ok 'certificate valid >7 days' || warn 'certificate expires within 7 days'; fi
sec '4. Loss / MTU / PMTU'
p="$(ping -4 -c 5 -W 2 "$PEER" 2>/dev/null || true)"; loss="$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' <<<"$p" | tail -1)"; avg="$(awk -F/ '/^(rtt|round-trip)/{print $5}' <<<"$p" | tail -1)"
if [[ -n "$avg" ]]; then fg "${loss:-100}" 2 && { warn "peer loss ${loss}% avg ${avg} ms"; NET=1; } || ok "peer loss ${loss:-0}% avg ${avg} ms"; else warn 'peer ICMP unavailable'; fi
iface="$(ip route show default | awk 'NR==1{print $5}')"; [[ -n "$iface" ]] && info "interface $iface MTU=$(cat /sys/class/net/$iface/mtu 2>/dev/null || echo '?')"
if [[ -n "$avg" ]]; then ping -4 -M do -s 1472 -c 1 -W 2 "$PEER" >/dev/null 2>&1 && ok 'DF 1472 works (IPv4 MTU 1500)' || { ping -4 -M do -s 1360 -c 1 -W 2 "$PEER" >/dev/null 2>&1 && warn 'DF 1472 fails; 1360 works' || warn 'DF 1360 also fails'; MTU=1; }; fi
if command -v tracepath >/dev/null; then tp="$(timeout 8 tracepath -4 -n -m 10 "$PEER" 2>/dev/null || true)"; pm="$(grep -oE 'pmtu [0-9]+' <<<"$tp" | tail -1 | awk '{print $2}')"; [[ -n "$pm" ]] && { ((pm<1400)) && { warn "PMTU=$pm"; MTU=1; } || ok "PMTU=$pm"; } || info 'tracepath PMTU unavailable'; fi
sec '5. Server resources / retransmission'
cpu="$(nproc)"; load="$(awk '{print $1}' /proc/loadavg)"; fg "$load" "$(awk -v c="$cpu" 'BEGIN{print c*2}')" && { warn "high load $load/$cpu"; RES=1; } || ok "load $load on $cpu CPU(s)"
mt="$(awk '/MemTotal/{print $2}' /proc/meminfo)"; ma="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"; mp="$(awk -v a="$ma" -v t="$mt" 'BEGIN{printf "%.1f",a*100/t}')"; fg 10 "$mp" && { warn "memory available ${mp}%"; RES=1; } || ok "memory available ${mp}%"
du="$(df -P / | awk 'NR==2{gsub(/%/,"",$5);print $5}')"; ((du>=90)) && { warn "disk ${du}% used"; RES=1; } || ok "disk ${du}% used"
readc(){ awk -v k="$1" '$1=="Tcp:"&&!s{for(i=2;i<=NF;i++)x[$i]=i;s=1;next}$1=="Tcp:"&&s{print $(x[k]);exit}' /proc/net/snmp; }; o1="$(readc OutSegs)"; q1="$(readc RetransSegs)"; sleep 3; o2="$(readc OutSegs)"; q2="$(readc RetransSegs)"; do=$((o2-o1)); dq=$((q2-q1)); if ((do>0)); then rp="$(awk -v r="$dq" -v o="$do" 'BEGIN{printf "%.2f",r*100/o}')"; fg "$rp" 2 && { warn "TCP retrans ${rp}%"; NET=1; } || ok "TCP retrans ${rp}%"; fi
WF=;WV=;TF=;TV=
if ((DEEP)); then
  sec '6. Deep throughput'
  if [[ "$ROLE" != iran ]]; then info 'Run --deep on Iran.'; elif ! command -v iperf3 >/dev/null; then warn 'iperf3 missing'; else
    nc -z -w2 127.0.0.1 10445 >/dev/null 2>&1 && { iperf 'WSS Iran -> Foreign' 10445 '' WF; iperf 'WSS Foreign -> Iran' 10445 1 WV; } || warn 'WSS diagnostic endpoint unavailable'
    nc -z -w2 127.0.0.1 11445 >/dev/null 2>&1 && { iperf 'TCP Iran -> Foreign' 11445 '' TF; iperf 'TCP Foreign -> Iran' 11445 1 TV; } || warn 'TCP diagnostic endpoint unavailable'
  fi
fi
sec 'Diagnosis'
if [[ "$ROLE" == foreign ]]; then
  if ((XR==0)); then fail 'LIKELY ROOT CAUSE: Xray is not listening on 127.0.0.1:443.'
  elif ((WT==0 && TC==1)); then warn 'LIKELY: WSS/443/SNI/TLS path problem; TCP remains reachable.'
  elif ((WT==1 && TC==0)); then warn 'LIKELY: TCPMux :3080 path/firewall issue.'
  elif ((WT==0 && TC==0)); then fail 'LIKELY: broader Iran/path/firewall reachability problem.'
  elif ((WT==1 && TC==1 && WR==0 && TR==1)); then warn 'LIKELY: WSSMux session/data-plane stall; TLS works and TCP health traffic continues.'
  elif ((RES)); then warn 'LIKELY: local resource pressure.'; elif ((NET||MTU)); then warn 'LIKELY: path loss/retransmission/PMTU issue.'; else ok 'Foreign-side core checks look healthy.'; fi
else
  if ((HT==0)); then fail 'LIKELY ROOT CAUSE: HAProxy config/service problem.'
  elif ((WH==0 && TH==1)); then warn 'LIKELY: WSS primary unavailable; TCP backup healthy and failover should be active.'
  elif ((WH==1 && TH==0)); then warn 'LIKELY: TCP backup unavailable; redundancy lost.'
  elif ((WH==0 && TH==0)); then fail 'LIKELY: Foreign/Xray/path failure; both transports failed.'
  elif ((RES)); then warn 'LIKELY: Iran resource pressure.'; elif ((NET||MTU)); then warn 'LIKELY: route/retransmission/PMTU issue.'
  elif ((DEEP)) && [[ -n "$WF" && -n "$TF" ]]; then awk -v w="$WF" -v t="$TF" 'BEGIN{exit !(w<t*.55)}' && warn 'LIKELY: WSS-specific speed degradation.' || { awk -v t="$TF" -v w="$WF" 'BEGIN{exit !(t<w*.55)}' && warn 'LIKELY: TCPMux-specific speed degradation.' || ok 'WSS and TCP throughput are in the same general range.'; }
  else ok 'Tunnel core looks healthy.'; fi
fi
if ((REPAIR)); then
  sec 'Repair'
  if [[ "$ROLE" == foreign && $WT -eq 1 && $TC -eq 1 && $WR -eq 0 && $TR -eq 1 ]] && active backhaul-wss; then warn 'WSS stall pattern matched; restarting only backhaul-wss.'; systemctl restart backhaul-wss; sleep 7; recent backhaul-wss 'connected to local address 127.0.0.1:18090 successfully' && ok 'WSS data-plane recovered.' || fail 'WSS did not recover after restart.'
  elif [[ "$ROLE" == iran && $WH -eq 0 && $TH -eq 1 && $HT -eq 1 ]] && active backhaul-wss; then warn 'WSS-down/TCP-healthy pattern matched; restarting only Iran backhaul-wss.'; systemctl restart backhaul-wss; sleep 6; curl -fsS --max-time 5 http://127.0.0.1:10444/healthz >/dev/null 2>&1 && ok 'WSS end-to-end recovered.' || warn 'Still down: likely Foreign WSS client stall; repair on Foreign.'
  else info 'No safe automatic repair condition matched; nothing restarted.'; fi
fi
printf '\nSummary: %d OK, %d WARN, %d FAIL\n' "$P" "$W" "$F"; ((F>0))&&exit 2; ((W>0))&&exit 1; exit 0

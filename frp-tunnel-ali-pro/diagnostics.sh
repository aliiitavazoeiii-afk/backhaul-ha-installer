#!/usr/bin/env bash
set -u
ETC=/etc/frp-tunnel-ali-pro
[[ -r "$ETC/meta.env" ]] && source "$ETC/meta.env"

echo '=== TIME ==='; date -u
echo '=== META ==='; grep -E '^(ROLE|IRAN_IP|FOREIGN_IP|DOMAIN|CONTROL_PORT|PUBLIC_PORT|PROFILE|LOCAL_PORT|VERSION)=' "$ETC/meta.env" 2>/dev/null || true

echo '=== SERVICES ==='
if [[ ${ROLE:-} == iran ]]; then
  systemctl status frp-tunnel-ali-pro --no-pager -l 2>&1 | head -n 35
  systemctl status nginx --no-pager -l 2>&1 | head -n 25
  echo '=== SOCKETS ==='
  ss -lntp | grep -E ":${CONTROL_PORT:-8443}|:${PUBLIC_PORT:-443}|:18443|:7500" || true
  echo '=== NGINX LIMITS ==='
  nginx -T 2>&1 | grep -E 'worker_processes|worker_rlimit_nofile|worker_connections' || true
  systemctl show nginx -p LimitNOFILE || true
  echo '=== NGINX RECENT ERRORS ==='
  tail -n 150 /var/log/nginx/error.log 2>/dev/null | grep -Ei 'worker_connections|too many open files|upstream|reset|timeout|failed|error' || true
  echo '=== FRPS RECENT ==='
  journalctl -u frp-tunnel-ali-pro --since '-10 min' --no-pager | tail -n 150
else
  for u in frp-tunnel-ali-pro frp-tunnel-ali-pro-shard@02 frp-tunnel-ali-pro-shard@03 frp-tunnel-ali-pro-shard@04; do systemctl status "$u" --no-pager -l 2>&1 | head -n 20; done
  echo '=== FRPC SOCKETS ==='; ss -tinp | grep -B1 -A4 frpc || true
  echo '=== FRPC RECENT ==='
  journalctl -u frp-tunnel-ali-pro -u 'frp-tunnel-ali-pro-shard@02' -u 'frp-tunnel-ali-pro-shard@03' -u 'frp-tunnel-ali-pro-shard@04' --since '-10 min' --no-pager | tail -n 200
fi

echo '=== TCP COUNTERS ==='
nstat -az 2>/dev/null | grep -E 'TcpRetransSegs|TcpTimeouts|TcpExtTCPAbort|TcpExtTCPSynRetrans|TcpExtTCPLoss|TcpExtTCPSpuriousRTO' || true

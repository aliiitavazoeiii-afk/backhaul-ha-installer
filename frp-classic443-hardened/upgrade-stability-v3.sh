#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] run as root' >&2; exit 1; }
TS="$(date +%Y%m%d-%H%M%S)"
ROLE=unknown
[[ -f /etc/frp-nomux/frps.toml ]] && ROLE=iran
[[ -f /etc/frp-nomux/frpc.toml ]] && ROLE=foreign
[[ "$ROLE" != unknown ]] || { echo '[x] FRP Classic443 installation not detected.' >&2; exit 1; }

echo "[+] Detected role: $ROLE"

safe_clear_swap(){
  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq '/swapfile-frp-resilience'; then
    avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    swap_used_kb="$(swapon --show=NAME,USED --bytes --noheadings 2>/dev/null | awk '$1=="/swapfile-frp-resilience" {print int($2/1024)}')"
    swap_used_kb="${swap_used_kb:-0}"
    if (( avail_kb > swap_used_kb + 262144 )); then
      swapoff /swapfile-frp-resilience
      swapon /swapfile-frp-resilience
      echo '[+] stale project swap pages cleared safely.'
    else
      echo '[i] swap left untouched; not enough free RAM for safe swapoff.'
    fi
  fi
}

if [[ "$ROLE" == iran ]]; then
  command -v haproxy >/dev/null 2>&1 || { echo '[x] haproxy missing' >&2; exit 1; }
  command -v nginx >/dev/null 2>&1 || { echo '[x] nginx missing' >&2; exit 1; }

  H=/etc/haproxy/haproxy.cfg
  N=/etc/nginx/conf.d/frp-nomux.conf
  F=/etc/frp-nomux/frps.toml
  [[ -f "$H" && -f "$N" && -f "$F" ]] || { echo '[x] Iran Classic443 config incomplete.' >&2; exit 1; }

  cp -a "$H" "$H.pre-stability-v3-${TS}.bak"
  cp -a "$N" "$N.pre-stability-v3-${TS}.bak"
  cp -a "$F" "$F.pre-stability-v3-${TS}.bak"

  python3 - "$H" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s=re.sub(r'(?m)^\s*timeout client\s+\S+\s*$', '    timeout client  24h', s)
s=re.sub(r'(?m)^\s*timeout server\s+\S+\s*$', '    timeout server  24h', s)
s=re.sub(r'(?m)^\s*tcp-request inspect-delay\s+\S+\s*$', '    tcp-request inspect-delay 10s', s)
if not re.search(r'(?m)^\s*option tcpka\s*$', s):
    s=s.replace('    option tcplog\n', '    option tcplog\n    option tcpka\n', 1)
s=re.sub(r'(?m)^\s*server local_nginx 127\.0\.0\.1:9443.*$',
         '    server local_nginx 127.0.0.1:9443 check inter 5s fall 2 rise 2', s)
s=re.sub(r'(?m)^\s*server frp_user 127\.0\.0\.1:10445.*$',
         '    server frp_user 127.0.0.1:10445', s)
s=re.sub(r'(?m)^\s*option redispatch\s*\n', '', s)
s=re.sub(r'(?m)^\s*retries\s+\d+\s*$', '    retries 0', s)
p.write_text(s)
PY

  python3 - "$N" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace('proxy_read_timeout 1d;', 'proxy_read_timeout 7d;')
s=s.replace('proxy_send_timeout 1d;', 'proxy_send_timeout 7d;')
if 'proxy_socket_keepalive on;' not in s:
    s=s.replace('        proxy_request_buffering off;\n', '        proxy_request_buffering off;\n        proxy_socket_keepalive on;\n', 1)
if 'proxy_connect_timeout 5s;' not in s:
    s=s.replace('        proxy_socket_keepalive on;\n', '        proxy_socket_keepalive on;\n        proxy_connect_timeout 5s;\n', 1)
p.write_text(s)
PY

  # Persist a more tolerant value for the next natural FRPS restart. No restart
  # is forced by this upgrade because user continuity is more important here.
  sed -E -i 's/^userConnTimeout[[:space:]]*=.*/userConnTimeout = 20/' "$F"

  if ! haproxy -c -f "$H" >/dev/null 2>&1; then
    cp -a "$H.pre-stability-v3-${TS}.bak" "$H"
    echo '[x] HAProxy validation failed; restored backup.' >&2
    exit 1
  fi
  if ! nginx -t >/dev/null 2>&1; then
    cp -a "$N.pre-stability-v3-${TS}.bak" "$N"
    echo '[x] nginx validation failed; restored backup.' >&2
    exit 1
  fi
  if ! /opt/frp-nomux/bin/frps verify -c "$F" >/dev/null 2>&1; then
    cp -a "$F.pre-stability-v3-${TS}.bak" "$F"
    echo '[x] frps validation failed; restored backup.' >&2
    exit 1
  fi

  mkdir -p /etc/systemd/system/nginx.service.d /etc/systemd/system/haproxy.service.d /etc/systemd/system/frps-nomux.service.d
  cat >/etc/systemd/system/nginx.service.d/frp-classic443.conf <<'EOF2'
[Service]
LimitNOFILE=262144
EOF2
  cat >/etc/systemd/system/haproxy.service.d/frp-classic443.conf <<'EOF2'
[Unit]
After=frps-nomux.service nginx.service
Wants=frps-nomux.service nginx.service

[Service]
LimitNOFILE=262144
EOF2
  cat >/etc/systemd/system/frps-nomux.service.d/20-frp-stability.conf <<'EOF2'
[Service]
MemoryMax=infinity
RestartSec=5s
TimeoutStopSec=10s
EOF2
  systemctl daemon-reload

  # Apply the old 512M MemoryMax removal live without restarting FRPS.
  systemctl set-property --runtime frps-nomux.service MemoryMax=infinity >/dev/null 2>&1 || true

  # Both are graceful reloads; established HAProxy/Nginx sessions are preserved.
  systemctl reload nginx
  systemctl reload haproxy

  echo '[+] IRAN stability-v3 applied with no FRPS restart.'
  echo '[i] userConnTimeout=20 is saved and will take effect on the next natural FRPS restart.'
  grep -nE 'timeout client|timeout server|option tcpka|inspect-delay|server local_nginx|server frp_user|retries' "$H" || true
  grep -nE 'proxy_(read|send|connect)_timeout|proxy_socket_keepalive' "$N" || true
  systemctl show frps-nomux -p ActiveState -p MemoryCurrent -p MemoryPeak -p MemoryMax -p NRestarts

else
  F=/etc/frp-nomux/frpc.toml
  cp -a "$F" "$F.pre-stability-v3-${TS}.bak"
  sed -E -i 's/^transport\.poolCount[[:space:]]*=.*/transport.poolCount = 8/' "$F"
  sed -E -i 's/^transport\.dialServerTimeout[[:space:]]*=.*/transport.dialServerTimeout = 12/' "$F"

  if ! grep -q '^transport\.heartbeatInterval' "$F"; then
    sed -i '/^transport\.dialServerKeepalive/a transport.heartbeatInterval = 30\ntransport.heartbeatTimeout = 90' "$F"
  fi
  if ! grep -q '^transport\.tls\.trustedCaFile' "$F"; then
    sed -i '/^transport\.tls\.serverName/a transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"' "$F"
  fi

  sed -i '/^healthCheck\.type = "tcp"$/,/^healthCheck\.intervalSeconds = /d' "$F"

  if ! /opt/frp-nomux/bin/frpc verify -c "$F" >/dev/null 2>&1; then
    cp -a "$F.pre-stability-v3-${TS}.bak" "$F"
    echo '[x] frpc validation failed; restored backup.' >&2
    exit 1
  fi

  mkdir -p /etc/systemd/system/frpc-nomux.service.d
  cat >/etc/systemd/system/frpc-nomux.service.d/20-frp-stability.conf <<'EOF2'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=6

[Service]
MemoryHigh=256M
MemoryMax=384M
MemorySwapMax=0
RestartSec=5s
TimeoutStopSec=10s
Environment=GOMEMLIMIT=192MiB
Environment=GOGC=75
EOF2
  systemctl daemon-reload

  echo '[i] Applying FOREIGN stability policy: one controlled FRPC restart now.'
  systemctl restart frpc-nomux
  sleep 4
  systemctl is-active --quiet frpc-nomux || {
    tail -n 100 /var/log/frp-nomux/frpc.log 2>/dev/null || true
    echo '[x] frpc-nomux failed after upgrade.' >&2
    exit 1
  }

  safe_clear_swap
  echo '[+] FOREIGN stability-v3 applied.'
  grep -E '^transport\.(poolCount|dialServerTimeout|heartbeatInterval|heartbeatTimeout|tls\.trustedCaFile)' "$F" || true
  systemctl show frpc-nomux -p ActiveState -p MainPID -p MemoryCurrent -p MemoryPeak -p MemorySwapCurrent -p MemoryMax -p NRestarts
  ps -C frpc -o pid,%cpu,%mem,rss,vsz,etime,cmd || true
  source /root/frp-nomux.env 2>/dev/null || true
  if [[ -n "${IRAN_IP:-}" ]]; then
    echo -n 'Established FRPC -> Iran:443 connections: '
    ss -Htn state established dst "${IRAN_IP}:443" | wc -l
  fi
fi

echo
echo '[+] Classic443 stability-v3 upgrade complete.'

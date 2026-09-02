#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-}"
BASE_COMMIT="335b749e97d1fe61d923c07dbd78a85da5e238b6"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${BASE_COMMIT}/frp-wss-nomux/install-standalone.sh"
PROFILE_VERSION="classic443-hardened-v3"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] run as root' >&2; exit 1; }
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo "Usage: $0 {iran|foreign}" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates python3 openssl >/dev/null

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 4 "$BASE_URL" -o "$tmp"

# Convert the field-proven 0.70.1 single-FRPC profile into the current
# production profile. No shards, tcpMux remains disabled, public carrier stays
# on :443 behind SNI routing.
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

def must(old,new):
    global s
    if old not in s:
        raise SystemExit(f"expected baseline pattern missing: {old[:100]!r}")
    s=s.replace(old,new,1)

# A small warm pool reduces idle connection count/churn while preserving burst
# capacity. poolCount is not a user/concurrency limit; FRP opens work conns on demand.
must('POOL_COUNT=20', 'POOL_COUNT=8')

# Generic service hardening. Role-specific memory policy is installed below.
must('RestartSec=2\nLimitNOFILE=1048576', 'RestartSec=5\nLimitNOFILE=262144\nTimeoutStopSec=10')

# Slightly more tolerant work/control dial during transient packet loss.
must('transport.dialServerTimeout = 8', 'transport.dialServerTimeout = 12')

# Verify the public certificate on Foreign instead of trusting an arbitrary TLS peer.
must('transport.tls.serverName = "$DOMAIN"\ntransport.tls.disableCustomTLSFirstByte = true',
     'transport.tls.serverName = "$DOMAIN"\ntransport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"\ntransport.tls.disableCustomTLSFirstByte = true')

# Explicit conservative heartbeat cadence.
must('transport.dialServerKeepalive = 30\ntransport.tls.enable = true',
     'transport.dialServerKeepalive = 30\ntransport.heartbeatInterval = 30\ntransport.heartbeatTimeout = 90\ntransport.tls.enable = true')

# Give FRPS longer to obtain a work connection during transient latency spikes.
must('userConnTimeout = 10', 'userConnTimeout = 20')

# IMPORTANT: do not health-poll local Xray through FRP. With tcpMux=false each
# health connection is a real work connection and can create continuous churn.
health='''healthCheck.type = "tcp"\nhealthCheck.timeoutSeconds = 2\nhealthCheck.maxFailed = 5\nhealthCheck.intervalSeconds = 2\n'''
if health not in s:
    raise SystemExit('expected FRP health-check block missing')
s=s.replace(health,'',1)

# Nginx capacity and long-lived WSS behavior.
s=s.replace('worker_rlimit_nofile 200000;', 'worker_rlimit_nofile 262144;')
s=s.replace('proxy_read_timeout 1d;', 'proxy_read_timeout 7d;')
s=s.replace('proxy_send_timeout 1d;', 'proxy_send_timeout 7d;')
must('        proxy_buffering off;\n        proxy_request_buffering off;',
     '        proxy_buffering off;\n        proxy_request_buffering off;\n        proxy_socket_keepalive on;\n        proxy_connect_timeout 5s;')

# Ordinary HTTPS probes to carrier SNI receive a benign page.
s=s.replace('    location / { return 404; }',
            "    location / { default_type text/html; return 200 '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>'; }")

# HAProxy reliability:
# - 10s inspect window avoids misrouting the carrier when ClientHello is delayed/fragmented.
# - 24h idle TCP timeouts avoid routine one-hour idle disconnects.
# - TCP keepalive helps clear dead half-open paths.
# - user backend has no active TCP health check: with no-mux that check itself traverses FRP.
s=s.replace('    option tcplog\n    timeout connect 5s\n    timeout client  1h\n    timeout server  1h',
            '    option tcplog\n    option tcpka\n    timeout connect 5s\n    timeout client  24h\n    timeout server  24h')
s=s.replace('    tcp-request inspect-delay 3s', '    tcp-request inspect-delay 10s')
s=s.replace('    server local_nginx 127.0.0.1:9443 check inter 2s fall 3 rise 2',
            '    server local_nginx 127.0.0.1:9443 check inter 5s fall 2 rise 2')
old_user='''backend frp_user_gateway\n    mode tcp\n    option redispatch\n    retries 2\n    server frp_user 127.0.0.1:$PROXY_PORT check inter 1s fall 2 rise 2'''
new_user='''backend frp_user_gateway\n    mode tcp\n    retries 0\n    server frp_user 127.0.0.1:$PROXY_PORT'''
must(old_user,new_user)

# No extra public test port: only 443 is exposed by this profile.
s=s.replace('    ufw allow "$TEST_PORT/tcp" >/dev/null\n','')
s=s.replace('  for p in 443 9443 "$FRPS_PORT" "$PROXY_PORT" "$TEST_PORT"; do',
            '  for p in 443 9443 "$FRPS_PORT" "$PROXY_PORT"; do')
s=s.replace('''\nfrontend frp_test_$TEST_PORT\n    bind *:$TEST_PORT\n    mode tcp\n    default_backend frp_user_gateway\n''','\n')
s=s.replace("    echo '=== PUBLIC ==='; ss -Hlnpt | grep -E ':(443|$TEST_PORT) ' || true",
            "    echo '=== PUBLIC ==='; ss -Hlnpt | grep -E ':443 ' || true")
s=s.replace('  echo "[+] Test endpoint: $IRAN_IP:$TEST_PORT"\n','')

p.write_text(s)
PY

bash -n "$tmp"

ensure_resilience(){
  # Emergency swap remains an OS safety net. FRPC itself is forbidden from
  # swapping by its role-specific systemd drop-in below.
  if ! swapon --show --noheadings 2>/dev/null | grep -q .; then
    mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
    if (( mem_kb < 3145728 && free_kb > 2097152 )); then
      swap=/swapfile-frp-resilience
      if [[ ! -f "$swap" ]]; then
        fallocate -l 1G "$swap" 2>/dev/null || dd if=/dev/zero of="$swap" bs=1M count=1024 status=none
        chmod 600 "$swap"
        mkswap "$swap" >/dev/null
      fi
      swapon "$swap" 2>/dev/null || true
      grep -Fq "$swap none swap sw 0 0" /etc/fstab || echo "$swap none swap sw 0 0" >> /etc/fstab
      echo 'vm.swappiness=10' >/etc/sysctl.d/99-frp-resilience.conf
      sysctl -q -p /etc/sysctl.d/99-frp-resilience.conf || true
      echo '[+] 1 GiB emergency swap enabled.'
    fi
  fi
}

install_iran_runtime_policy(){
  mkdir -p /etc/systemd/system/nginx.service.d /etc/systemd/system/haproxy.service.d
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
  systemctl daemon-reload
}

install_foreign_runtime_policy(){
  mkdir -p /etc/systemd/system/frpc-nomux.service.d
  cat >/etc/systemd/system/frpc-nomux.service.d/20-frp-stability.conf <<'EOF2'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=6

[Service]
# Normal frpc usage is expected to stay far below these values. MemoryHigh is
# deliberately well above normal operation and acts only before a runaway.
MemoryHigh=256M
MemoryMax=384M
MemorySwapMax=0
RestartSec=5s
TimeoutStopSec=10s
Environment=GOMEMLIMIT=192MiB
Environment=GOGC=75
EOF2
  systemctl daemon-reload
}

clear_project_swap_if_safe(){
  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq '/swapfile-frp-resilience'; then
    avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    swap_used_kb="$(swapon --show=NAME,USED --bytes --noheadings 2>/dev/null | awk '$1=="/swapfile-frp-resilience" {print int($2/1024)}')"
    swap_used_kb="${swap_used_kb:-0}"
    if (( avail_kb > swap_used_kb + 262144 )); then
      swapoff /swapfile-frp-resilience
      swapon /swapfile-frp-resilience
      echo '[+] stale project swap pages cleared safely.'
    fi
  fi
}

if [[ "$ROLE" == iran ]]; then
  read -r -p 'Iran public IPv4: ' IRAN_IP
  read -r -p "Dedicated FRP carrier domain (must differ from users' Reality SNI): " DOMAIN
  bash "$tmp" --role iran --iran-ip "$IRAN_IP" --domain "$DOMAIN"
  ensure_resilience
  install_iran_runtime_policy
  nginx -t >/dev/null
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null
  systemctl restart nginx
  systemctl restart haproxy
  echo
  echo 'PAIR CODE (secret — paste only into the Foreign installer):'
  base64 -w0 /root/frp-nomux.env
  echo
  echo
  echo "[+] Iran ${PROFILE_VERSION} ready."
  frpctl status
else
  read -r -s -p 'Paste PAIR CODE from Iran: ' PAIR
  echo
  printf '%s' "$PAIR" | base64 -d >/root/frp-nomux.env 2>/dev/null || { echo '[x] invalid pair code' >&2; exit 1; }
  chmod 600 /root/frp-nomux.env
  bash "$tmp" --role foreign --bundle /root/frp-nomux.env
  ensure_resilience
  install_foreign_runtime_policy
  systemctl restart frpc-nomux
  sleep 4
  systemctl is-active --quiet frpc-nomux || {
    tail -n 100 /var/log/frp-nomux/frpc.log 2>/dev/null || true
    echo '[x] frpc-nomux did not come back up.' >&2
    exit 1
  }
  clear_project_swap_if_safe
  echo "[+] Foreign ${PROFILE_VERSION} ready; Xray/3x-ui untouched."
  frpctl status
  echo '=== FRPC RESOURCE POLICY ==='
  systemctl show frpc-nomux -p MemoryCurrent -p MemoryPeak -p MemorySwapCurrent -p MemoryMax -p NRestarts
  ps -C frpc -o pid,%cpu,%mem,rss,vsz,etime,cmd || true
fi

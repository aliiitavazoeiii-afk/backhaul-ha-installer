#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-}"
BASE_COMMIT="335b749e97d1fe61d923c07dbd78a85da5e238b6"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${BASE_COMMIT}/frp-wss-nomux/install-standalone.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] run as root' >&2; exit 1; }
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo "Usage: $0 {iran|foreign}" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates python3 openssl >/dev/null

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 4 "$BASE_URL" -o "$tmp"

# Convert the old field-proven single-FRPC profile into the hardened production profile.
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

def must(old,new):
    global s
    if old not in s:
        raise SystemExit(f"expected baseline pattern missing: {old[:80]!r}")
    s=s.replace(old,new,1)

# Keep the proven 0.70.1 / one FRPC / tcpMux=false / pool=20 baseline.
must('RestartSec=2\nLimitNOFILE=1048576', 'RestartSec=5\nLimitNOFILE=262144\nMemoryMax=512M')

# Verify the public certificate on Foreign instead of trusting an arbitrary TLS peer.
must('transport.tls.serverName = "$DOMAIN"\ntransport.tls.disableCustomTLSFirstByte = true',
     'transport.tls.serverName = "$DOMAIN"\ntransport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"\ntransport.tls.disableCustomTLSFirstByte = true')

# Explicit conservative heartbeat cadence; avoid aggressive reconnect chatter.
must('transport.dialServerKeepalive = 30\ntransport.tls.enable = true',
     'transport.dialServerKeepalive = 30\ntransport.heartbeatInterval = 30\ntransport.heartbeatTimeout = 90\ntransport.tls.enable = true')

# Remove local-Xray health polling from FRP itself. A temporary Xray hiccup must not churn proxy registration.
health='''healthCheck.type = "tcp"\nhealthCheck.timeoutSeconds = 2\nhealthCheck.maxFailed = 5\nhealthCheck.intervalSeconds = 2\n'''
if health not in s:
    raise SystemExit('expected FRP health-check block missing')
s=s.replace(health,'',1)

# Nginx capacity and long-lived WSS behavior.
s=s.replace('worker_rlimit_nofile 200000;', 'worker_rlimit_nofile 262144;')
s=s.replace('proxy_read_timeout 1d;', 'proxy_read_timeout 7d;')
s=s.replace('proxy_send_timeout 1d;', 'proxy_send_timeout 7d;')
must('        proxy_buffering off;\n        proxy_request_buffering off;',
     '        proxy_buffering off;\n        proxy_request_buffering off;\n        proxy_socket_keepalive on;')

# Ordinary HTTPS probes to the carrier SNI get a benign response rather than FRP-specific behavior.
s=s.replace('    location / { return 404; }',
            "    location / { default_type text/html; return 200 '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>'; }")

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
  # Prevent a tunnel bug from making SSH/Xray unreachable on small VPS nodes.
  mkdir -p /etc/systemd/system/nginx.service.d /etc/systemd/system/haproxy.service.d
  if systemctl list-unit-files nginx.service >/dev/null 2>&1; then
    cat >/etc/systemd/system/nginx.service.d/frp-classic443.conf <<'EOF2'
[Service]
LimitNOFILE=262144
EOF2
  fi
  if systemctl list-unit-files haproxy.service >/dev/null 2>&1; then
    cat >/etc/systemd/system/haproxy.service.d/frp-classic443.conf <<'EOF2'
[Service]
LimitNOFILE=262144
EOF2
  fi
  systemctl daemon-reload

  # Emergency swap only for small no-swap VPSes and only when disk space is sufficient.
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

if [[ "$ROLE" == iran ]]; then
  read -r -p 'Iran public IPv4: ' IRAN_IP
  read -r -p "Dedicated FRP carrier domain (do NOT use it as users' Reality SNI): " DOMAIN
  bash "$tmp" --role iran --iran-ip "$IRAN_IP" --domain "$DOMAIN"
  ensure_resilience
  nginx -t >/dev/null && systemctl reload nginx
  systemctl restart haproxy
  echo
  echo 'PAIR CODE (secret — paste only into the Foreign installer):'
  base64 -w0 /root/frp-nomux.env
  echo
  echo
  echo '[+] Iran hardened classic-443 profile ready.'
  frpctl status
else
  read -r -s -p 'Paste PAIR CODE from Iran: ' PAIR
  echo
  printf '%s' "$PAIR" | base64 -d >/root/frp-nomux.env 2>/dev/null || { echo '[x] invalid pair code' >&2; exit 1; }
  chmod 600 /root/frp-nomux.env
  bash "$tmp" --role foreign --bundle /root/frp-nomux.env
  ensure_resilience
  systemctl daemon-reload
  systemctl restart frpc-nomux
  sleep 3
  echo '[+] Foreign hardened classic-443 profile ready; Xray/3x-ui untouched.'
  frpctl status
fi

#!/usr/bin/env bash
set -Eeuo pipefail

PROFILE_VERSION="classic443-mux-v4-final"
FRP_VERSION="0.70.1"
FRP_DIR="/opt/frp-nomux"
CFG_DIR="/etc/frp-nomux"
LOG_DIR="/var/log/frp-nomux"
TOKEN_FILE="$CFG_DIR/token"
PAIR_FILE="/root/frp-nomux.env"
FRPS_PORT=18081
PROXY_PORT=10445
POOL_COUNT=128
MAX_POOL_COUNT=256

ROLE="${1:-}"
log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || die "Usage: $0 {iran|foreign}"

valid_ip(){ python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1])
except Exception: raise SystemExit(1)
PY
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
port_busy(){ ss -Hlnpt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$1$"; }

install_base_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates tar openssl python3 iproute2 >/dev/null
}

asset_info(){
  case "$(uname -m)" in
    x86_64|amd64) echo "linux_amd64 333da23d1b9009d7c01638e9ba38cf4600f7d37d393f854e96ee1396adefa9a6";;
    aarch64|arm64) echo "linux_arm64 3990f396a9a490ee7f0e5f355287750ed41520064ed999eab443b5e9a78d773d";;
    *) die "unsupported architecture: $(uname -m)";;
  esac
}

install_frp(){
  install -d -m 0755 "$FRP_DIR/bin" "$CFG_DIR" "$LOG_DIR"
  local asset sha tmp arc root
  read -r asset sha <<<"$(asset_info)"
  arc="frp_${FRP_VERSION}_${asset}.tar.gz"
  tmp="$(mktemp -d)"
  curl -fL --retry 4 --connect-timeout 10 \
    "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${arc}" -o "$tmp/$arc"
  echo "$sha  $tmp/$arc" | sha256sum -c - >/dev/null || { rm -rf "$tmp"; die "FRP SHA256 mismatch"; }
  tar -xzf "$tmp/$arc" -C "$tmp"
  root="$tmp/frp_${FRP_VERSION}_${asset}"
  install -m 0755 "$root/frps" "$FRP_DIR/bin/frps"
  install -m 0755 "$root/frpc" "$FRP_DIR/bin/frpc"
  "$FRP_DIR/bin/frps" --version | grep -Fq "$FRP_VERSION" || die "wrong frps version"
  "$FRP_DIR/bin/frpc" --version | grep -Fq "$FRP_VERSION" || die "wrong frpc version"
  rm -rf "$tmp"
  log "FRP $FRP_VERSION installed from pinned official release"
}

backup_file(){
  local src="$1" dst="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

write_unit(){
  local service="$1" bin="$2" cfg="$3"
  cat >"/etc/systemd/system/${service}.service" <<EOF2
[Unit]
Description=FRP Classic443 Mux-v4 ${service}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$FRP_DIR/bin/$bin -c $CFG_DIR/$cfg
Restart=always
RestartSec=5s
TimeoutStopSec=10s
LimitNOFILE=262144
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$LOG_DIR

[Install]
WantedBy=multi-user.target
EOF2
}

write_frps(){
  cat >"$CFG_DIR/frps.toml" <<EOF2
bindAddr = "127.0.0.1"
bindPort = $FRPS_PORT
proxyBindAddr = "127.0.0.1"
transport.maxPoolCount = $MAX_POOL_COUNT
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30
transport.tcpKeepalive = 30
transport.tls.force = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$TOKEN_FILE"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

allowPorts = [{ single = $PROXY_PORT }]
maxPortsPerClient = 1
userConnTimeout = 30

log.to = "$LOG_DIR/frps.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true
EOF2
  chmod 0600 "$CFG_DIR/frps.toml"
}

write_frpc(){
  cat >"$CFG_DIR/frpc.toml" <<EOF2
clientID = "frp-classic443-mux-primary"
serverAddr = "$IRAN_IP"
serverPort = 443
loginFailExit = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$TOKEN_FILE"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

transport.protocol = "wss"
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30
transport.poolCount = $POOL_COUNT
transport.dialServerTimeout = 12
transport.dialServerKeepalive = 30
transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90
transport.tls.enable = true
transport.tls.serverName = "$DOMAIN"
transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"
transport.tls.disableCustomTLSFirstByte = true

log.to = "$LOG_DIR/frpc.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true

[[proxies]]
name = "xray-tcp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 443
remotePort = $PROXY_PORT
transport.useEncryption = false
transport.useCompression = false
EOF2
  chmod 0600 "$CFG_DIR/frpc.toml"
}

write_iran_nginx(){
  rm -f /etc/nginx/sites-enabled/default
  cat >/etc/nginx/conf.d/frp-nomux.conf <<EOF2
server {
    listen 127.0.0.1:9443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:FRPSSL:20m;
    ssl_session_timeout 1d;

    location = /~!frp {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_connect_timeout 5s;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_pass http://127.0.0.1:$FRPS_PORT;
    }

    location / {
        default_type text/html;
        return 200 '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>';
    }
}
EOF2
}

tune_nginx(){
  python3 - <<'PY'
from pathlib import Path
import re
p=Path('/etc/nginx/nginx.conf')
s=p.read_text()
if 'worker_rlimit_nofile' in s:
    s=re.sub(r'worker_rlimit_nofile\s+\d+\s*;', 'worker_rlimit_nofile 262144;', s, count=1)
else:
    m=re.search(r'(?m)^user\s+[^;]+;\s*$',s)
    if m:
        s=s[:m.end()]+"\nworker_rlimit_nofile 262144;"+s[m.end():]
    else:
        s="worker_rlimit_nofile 262144;\n"+s
s=re.sub(r'worker_connections\s+\d+\s*;', 'worker_connections 65535;', s, count=1)
p.write_text(s)
PY
}

write_haproxy(){
  cat >/etc/haproxy/haproxy.cfg <<EOF2
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 50000
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option tcpka
    timeout connect 5s
    timeout client  24h
    timeout server  24h

frontend public_443
    bind *:443
    mode tcp
    tcp-request inspect-delay 10s
    tcp-request content accept if { req_ssl_hello_type 1 }
    acl frp_carrier req.ssl_sni -i $DOMAIN
    use_backend frp_carrier_tls if frp_carrier
    default_backend frp_user_gateway

backend frp_carrier_tls
    mode tcp
    server local_nginx 127.0.0.1:9443 check inter 5s fall 2 rise 2

backend frp_user_gateway
    mode tcp
    retries 0
    server frp_user 127.0.0.1:$PROXY_PORT
EOF2
}

write_frpctl_iran(){
  cat >/usr/local/bin/frpctl <<EOF2
#!/usr/bin/env bash
set -u
case "\${1:-status}" in
  status)
    echo '=== FRPS ==='; systemctl is-active frps-nomux || true
    echo '=== NGINX ==='; systemctl is-active nginx || true
    echo '=== HAPROXY ==='; systemctl is-active haproxy || true
    echo '=== FRP USER PROXY ==='; ss -Hlnpt | grep -q '127.0.0.1:$PROXY_PORT ' && echo UP || echo DOWN
    echo '=== PUBLIC ==='; ss -Hlnpt | grep -E ':443 ' || true
    ;;
  logs) tail -n 120 '$LOG_DIR/frps.log' 2>/dev/null || true;;
  *) echo 'Usage: frpctl {status|logs}' >&2; exit 2;;
esac
EOF2
  chmod 0755 /usr/local/bin/frpctl
}

write_frpctl_foreign(){
  cat >/usr/local/bin/frpctl <<EOF2
#!/usr/bin/env bash
set -u
case "\${1:-status}" in
  status)
    echo '=== FRPC ==='; systemctl is-active frpc-nomux || true
    echo '=== XRAY LOCAL ==='; timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null && echo UP || echo DOWN
    echo '=== WSS TCP CONNECTIONS TO IRAN ==='; ss -Htn state established dst $IRAN_IP:443 | wc -l
    ;;
  logs) tail -n 120 '$LOG_DIR/frpc.log' 2>/dev/null || true;;
  *) echo 'Usage: frpctl {status|logs}' >&2; exit 2;;
esac
EOF2
  chmod 0755 /usr/local/bin/frpctl
}

maybe_open_ufw(){
  command -v ufw >/dev/null || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
}

issue_cert(){
  if [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
    log "existing certificate found for $DOMAIN"
    return
  fi
  port_busy 80 && die "port 80 is busy; cannot run standalone ACME challenge"
  certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email \
    --preferred-challenges http -d "$DOMAIN"
}

ensure_resilience_swap(){
  if ! swapon --show --noheadings 2>/dev/null | grep -q .; then
    local mem_kb free_kb swap
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
      log "1 GiB emergency OS swap enabled"
    fi
  fi
}

install_iran_runtime_policy(){
  mkdir -p /etc/systemd/system/nginx.service.d /etc/systemd/system/haproxy.service.d /etc/systemd/system/frps-nomux.service.d
  rm -f /etc/systemd/system/frps-nomux.service.d/20-frp-stability.conf
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
  cat >/etc/systemd/system/frps-nomux.service.d/30-mux-v4.conf <<'EOF2'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=6

[Service]
RestartSec=5s
TimeoutStopSec=10s
LimitNOFILE=262144
EOF2
  systemctl daemon-reload
}

install_foreign_runtime_policy(){
  mkdir -p /etc/systemd/system/frpc-nomux.service.d
  rm -f /etc/systemd/system/frpc-nomux.service.d/20-frp-stability.conf
  cat >/etc/systemd/system/frpc-nomux.service.d/30-mux-v4.conf <<'EOF2'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=6

[Service]
MemoryHigh=512M
MemoryMax=768M
MemorySwapMax=0
RestartSec=5s
TimeoutStopSec=10s
LimitNOFILE=262144
Environment=GOMEMLIMIT=512MiB
Environment=GOGC=100
EOF2
  systemctl daemon-reload
}

preflight_iran(){
  for p in 443 9443 "$FRPS_PORT" "$PROXY_PORT"; do
    port_busy "$p" && die "TCP port $p is already in use; refusing to overwrite a live service"
  done
  if systemctl is-active --quiet haproxy 2>/dev/null; then
    die "HAProxy is already active; refusing to overwrite an unrelated live config"
  fi
  if systemctl is-active --quiet nginx 2>/dev/null; then
    die "Nginx is already active; refusing to stop an unrelated live service"
  fi
}

install_iran(){
  install_base_deps
  read -r -p 'Iran public IPv4: ' IRAN_IP
  read -r -p "Dedicated FRP carrier domain (must differ from users' Reality SNI): " DOMAIN
  valid_ip "$IRAN_IP" || die "invalid Iran IPv4"
  valid_domain "$DOMAIN" || die "invalid carrier domain"

  local dns_ips
  dns_ips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  echo "$dns_ips" | grep -Fxq "$IRAN_IP" || die "$DOMAIN does not currently resolve to $IRAN_IP"

  preflight_iran
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq haproxy nginx certbot >/dev/null
  systemctl stop nginx haproxy 2>/dev/null || true

  install_frp
  [[ -s "$TOKEN_FILE" ]] || { umask 077; openssl rand -hex 32 >"$TOKEN_FILE"; }
  chmod 0600 "$TOKEN_FILE"

  maybe_open_ufw
  issue_cert

  local bak="/root/frp-nomux-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$bak"
  backup_file /etc/nginx/nginx.conf "$bak/nginx.conf"
  backup_file /etc/nginx/conf.d/frp-nomux.conf "$bak/frp-nomux.conf"
  backup_file /etc/haproxy/haproxy.cfg "$bak/haproxy.cfg"

  tune_nginx
  write_frps
  write_iran_nginx
  write_haproxy
  write_unit frps-nomux frps frps.toml
  write_frpctl_iran
  install_iran_runtime_policy
  ensure_resilience_swap

  "$FRP_DIR/bin/frps" verify -c "$CFG_DIR/frps.toml" >/dev/null || die "frps config validation failed"
  nginx -t >/dev/null || die "nginx config validation failed"
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null || die "haproxy config validation failed"

  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/frp-nomux-nginx <<'EOF2'
#!/usr/bin/env bash
systemctl reload nginx
EOF2
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/frp-nomux-nginx

  umask 077
  cat >"$PAIR_FILE" <<EOF2
ROLE='foreign'
IRAN_IP='$IRAN_IP'
DOMAIN='$DOMAIN'
TOKEN='$(cat "$TOKEN_FILE")'
FRP_VERSION='$FRP_VERSION'
PROFILE_VERSION='$PROFILE_VERSION'
EOF2
  chmod 0600 "$PAIR_FILE"

  systemctl daemon-reload
  systemctl enable --now frps-nomux >/dev/null
  systemctl enable --now nginx >/dev/null
  systemctl enable --now haproxy >/dev/null
  sleep 3
  systemctl is-active --quiet frps-nomux || die "frps-nomux failed"
  systemctl is-active --quiet nginx || die "nginx failed"
  systemctl is-active --quiet haproxy || die "haproxy failed"

  echo
  echo 'PAIR CODE (secret — paste only into the Foreign installer):'
  base64 -w0 "$PAIR_FILE"
  echo
  echo
  log "Iran $PROFILE_VERSION ready"
  echo "[+] User endpoint: $IRAN_IP:443"
  echo "[i] FRP USER PROXY stays DOWN until Foreign connects"
  frpctl status
}

load_pair_code(){
  local pair
  read -r -s -p 'Paste PAIR CODE from Iran: ' pair
  echo
  printf '%s' "$pair" | base64 -d >"$PAIR_FILE" 2>/dev/null || die "invalid pair code"
  chmod 0600 "$PAIR_FILE"
  # shellcheck disable=SC1090
  source "$PAIR_FILE"
  [[ "${ROLE:-}" == foreign ]] || die "invalid pair role"
  valid_ip "${IRAN_IP:-}" || die "invalid IRAN_IP in pair code"
  valid_domain "${DOMAIN:-}" || die "invalid DOMAIN in pair code"
  [[ "${TOKEN:-}" =~ ^[0-9a-f]{64}$ ]] || die "invalid token in pair code"
  [[ "${FRP_VERSION:-}" == "0.70.1" ]] || die "unexpected FRP version in pair code"
  [[ "${PROFILE_VERSION:-}" == "classic443-mux-v4-final" ]] || die "pair code is not from final mux-v4 Iran installer"
}

install_foreign(){
  install_base_deps
  load_pair_code
  timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null || die "Xray is not listening on 127.0.0.1:443; nothing changed"

  if systemctl is-active --quiet frpc-nomux 2>/dev/null; then
    die "frpc-nomux is already active; uninstall the old Classic443 tunnel before a fresh install"
  fi

  install_frp
  umask 077
  printf '%s\n' "$TOKEN" >"$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"
  write_frpc
  write_unit frpc-nomux frpc frpc.toml
  write_frpctl_foreign
  install_foreign_runtime_policy
  ensure_resilience_swap

  "$FRP_DIR/bin/frpc" verify -c "$CFG_DIR/frpc.toml" >/dev/null || die "frpc config validation failed"

  systemctl daemon-reload
  : >"$LOG_DIR/frpc.log"
  systemctl enable --now frpc-nomux >/dev/null

  local ok=0
  for _ in {1..20}; do
    if grep -Fq '[xray-tcp] start proxy success' "$LOG_DIR/frpc.log" 2>/dev/null; then ok=1; break; fi
    sleep 1
  done
  if ((ok == 0)); then
    tail -n 80 "$LOG_DIR/frpc.log" 2>/dev/null || true
    die "frpc started but did not register successfully"
  fi

  log "Foreign $PROFILE_VERSION ready; Xray/3x-ui untouched"
  frpctl status
  echo '=== FRPC RESOURCE POLICY ==='
  systemctl show frpc-nomux -p MemoryCurrent -p MemoryPeak -p MemorySwapCurrent -p MemoryMax -p NRestarts
  ps -C frpc -o pid,%cpu,%mem,rss,vsz,nlwp,etime,cmd || true
}

case "$ROLE" in
  iran) install_iran;;
  foreign) install_foreign;;
esac

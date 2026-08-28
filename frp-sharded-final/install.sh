#!/usr/bin/env bash
set -Eeuo pipefail

FRP_VERSION="0.70.1"
FRP_DIR="/opt/frp-sharded"
CFG_DIR="/etc/frp-sharded"
LOG_DIR="/var/log/frp-sharded"
TOKEN_FILE="$CFG_DIR/token"
GROUP_FILE="$CFG_DIR/group.key"
BUNDLE_OUT="/root/frp-sharded-bundle.tar.gz"
FRPS_PORT=18083
PROXY_PORT=10447
CARRIER_PORT=8443
TEST_PORT=2444
SHARDS=16
POOL_COUNT=4
MAX_POOL_COUNT=8
ROLE=""
IRAN_IP=""
DOMAIN=""
BUNDLE=""

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

usage(){ cat <<'USAGE'
Fresh Iran server:
  bash install.sh --role iran --iran-ip 203.0.113.10 --domain tunnel.example.com

Foreign server with existing Xray on 127.0.0.1:443:
  bash install.sh --role foreign --bundle /root/frp-sharded-bundle.tar.gz
USAGE
}

while (($#)); do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --iran-ip) IRAN_IP="${2:-}"; shift 2;;
    --domain) DOMAIN="${2:-}"; shift 2;;
    --bundle) BUNDLE="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root"
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || die "--role must be iran or foreign"

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
  apt-get install -y -qq curl ca-certificates tar openssl python3 iproute2
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
  curl -fL --retry 3 --connect-timeout 10 \
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

maybe_open_ufw_iran(){
  command -v ufw >/dev/null || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow "$CARRIER_PORT/tcp" >/dev/null
  ufw allow "$TEST_PORT/tcp" >/dev/null
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

tune_nginx(){
  python3 - <<'PY'
from pathlib import Path
import re
p=Path('/etc/nginx/nginx.conf')
s=p.read_text()
if 'worker_rlimit_nofile' not in s:
    m=re.search(r'(?m)^user\s+[^;]+;\s*$',s)
    if m:
        s=s[:m.end()]+"\nworker_rlimit_nofile 200000;"+s[m.end():]
    else:
        s="worker_rlimit_nofile 200000;\n"+s
s=re.sub(r'worker_connections\s+\d+\s*;', 'worker_connections 65535;', s, count=1)
p.write_text(s)
PY
}

write_frps(){
  [[ -s "$TOKEN_FILE" ]] || { umask 077; openssl rand -hex 32 >"$TOKEN_FILE"; }
  [[ -s "$GROUP_FILE" ]] || { umask 077; openssl rand -hex 32 >"$GROUP_FILE"; }
  chmod 0600 "$TOKEN_FILE" "$GROUP_FILE"

  cat >"$CFG_DIR/frps.toml" <<EOF_FRPS
bindAddr = "127.0.0.1"
bindPort = $FRPS_PORT
proxyBindAddr = "127.0.0.1"
transport.maxPoolCount = $MAX_POOL_COUNT
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 20
transport.tcpKeepalive = 30
transport.tls.force = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$TOKEN_FILE"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

allowPorts = [{ single = $PROXY_PORT }]
maxPortsPerClient = 1
userConnTimeout = 5

log.to = "$LOG_DIR/frps.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true
EOF_FRPS
  chmod 0600 "$CFG_DIR/frps.toml"

  cat >/etc/systemd/system/frps-sharded.service <<EOF_UNIT
[Unit]
Description=FRP 16-shard mux server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$FRP_DIR/bin/frps -c $CFG_DIR/frps.toml
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$LOG_DIR

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

write_nginx(){
  rm -f /etc/nginx/sites-enabled/default
  cat >/etc/nginx/conf.d/frp-sharded.conf <<EOF_NGINX
server {
    listen 0.0.0.0:$CARRIER_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:FRPSHARD:20m;
    ssl_session_timeout 1d;

    location = /~!frp {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_pass http://127.0.0.1:$FRPS_PORT;
    }

    location / { return 404; }
}
EOF_NGINX
}

write_haproxy(){
  cat >/etc/haproxy/haproxy.cfg <<EOF_HAPROXY
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
    timeout connect 5s
    timeout client  1h
    timeout server  1h

backend frp_sharded_gateway
    mode tcp
    option redispatch
    retries 2
    server frp_sharded 127.0.0.1:$PROXY_PORT check inter 1s fall 2 rise 2

frontend public_443
    bind *:443
    mode tcp
    default_backend frp_sharded_gateway

frontend test_$TEST_PORT
    bind *:$TEST_PORT
    mode tcp
    default_backend frp_sharded_gateway
EOF_HAPROXY
}

write_iran_ctl(){
  cat >/usr/local/bin/frp-shardctl <<EOF_CTL
#!/usr/bin/env bash
set -u
case "\${1:-status}" in
 status)
   echo '=== SHARDED FRPS ==='; systemctl is-active frps-sharded || true
   echo '=== NGINX CARRIER ==='; systemctl is-active nginx || true
   echo '=== HAPROXY USER EDGE ==='; systemctl is-active haproxy || true
   echo '=== SHARDED USER PROXY ==='; ss -Hlnpt | grep -q '127.0.0.1:$PROXY_PORT ' && echo UP || echo DOWN
   echo -n 'carrier tcp sessions on :$CARRIER_PORT: '; ss -Htn state established sport = :$CARRIER_PORT 2>/dev/null | wc -l
   echo -n 'active user backend streams: '; ss -Htn state established dst 127.0.0.1:$PROXY_PORT 2>/dev/null | wc -l
   echo '=== PUBLIC LISTENERS ==='; ss -Hlnpt | grep -E ':(443|$CARRIER_PORT|$TEST_PORT) ' || true
   ;;
 logs)
   tail -n 120 '$LOG_DIR/frps.log' 2>/dev/null || true
   ;;
 *) echo 'Usage: frp-shardctl {status|logs}' >&2; exit 2;;
esac
EOF_CTL
  chmod 0755 /usr/local/bin/frp-shardctl
}

make_bundle(){
  local tmp
  tmp="$(mktemp -d)"
  umask 077
  cat >"$tmp/env" <<EOF_BUNDLE
ROLE='foreign'
IRAN_IP='$IRAN_IP'
DOMAIN='$DOMAIN'
TOKEN='$(cat "$TOKEN_FILE")'
GROUP_KEY='$(cat "$GROUP_FILE")'
FRP_VERSION='$FRP_VERSION'
SHARDS='$SHARDS'
POOL_COUNT='$POOL_COUNT'
EOF_BUNDLE
  tar -C "$tmp" -czf "$BUNDLE_OUT" env
  chmod 0600 "$BUNDLE_OUT"
  rm -rf "$tmp"
}

load_bundle(){
  [[ -n "$BUNDLE" && -s "$BUNDLE" ]] || die "--bundle file required"
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$BUNDLE" -C "$tmp" env
  # shellcheck disable=SC1090
  source "$tmp/env"
  rm -rf "$tmp"
  [[ "${ROLE:-}" == foreign ]] || die "invalid bundle role"
  valid_ip "$IRAN_IP" || die "invalid IRAN_IP in bundle"
  valid_domain "$DOMAIN" || die "invalid DOMAIN in bundle"
  [[ "${TOKEN:-}" =~ ^[0-9a-f]{64}$ ]] || die "invalid token"
  [[ "${GROUP_KEY:-}" =~ ^[0-9a-f]{64}$ ]] || die "invalid group key"
  [[ "${FRP_VERSION:-}" == "0.70.1" ]] || die "unexpected FRP version"
  [[ "${SHARDS:-}" == "16" ]] || die "unexpected shard count"
  [[ "${POOL_COUNT:-}" == "4" ]] || die "unexpected pool count"
}

write_foreign_configs(){
  umask 077
  printf '%s\n' "$TOKEN" >"$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"

  for i in $(seq -w 1 "$SHARDS"); do
    cat >"$CFG_DIR/frpc-$i.toml" <<EOF_FRPC
clientID = "frp-shard-$i"
serverAddr = "$IRAN_IP"
serverPort = $CARRIER_PORT
loginFailExit = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$TOKEN_FILE"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

transport.protocol = "wss"
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 20
transport.poolCount = $POOL_COUNT
transport.dialServerTimeout = 8
transport.dialServerKeepalive = 30
transport.tls.enable = true
transport.tls.serverName = "$DOMAIN"
transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"
transport.tls.disableCustomTLSFirstByte = true

log.to = "$LOG_DIR/frpc-$i.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true

[[proxies]]
name = "xray-shard-$i"
type = "tcp"
localIP = "127.0.0.1"
localPort = 443
remotePort = $PROXY_PORT
loadBalancer.group = "xray-sharded-v1"
loadBalancer.groupKey = "$GROUP_KEY"
transport.useEncryption = false
transport.useCompression = false
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 2
healthCheck.maxFailed = 5
healthCheck.intervalSeconds = 2
EOF_FRPC
    chmod 0600 "$CFG_DIR/frpc-$i.toml"
  done

  cat >/etc/systemd/system/frpc-shard@.service <<EOF_UNIT
[Unit]
Description=FRP mux shard %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$FRP_DIR/bin/frpc -c $CFG_DIR/frpc-%i.toml
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$LOG_DIR

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

write_foreign_ctl(){
  cat >/usr/local/bin/frp-shardctl <<EOF_CTL
#!/usr/bin/env bash
set -u
case "\${1:-status}" in
 status)
   active=0
   for i in \$(seq -w 1 $SHARDS); do systemctl is-active --quiet frpc-shard@\$i && active=\$((active+1)); done
   echo "active shard services: \$active/$SHARDS"
   echo -n 'Xray local: '; timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null && echo UP || echo DOWN
   echo -n 'TCP sessions to Iran:$CARRIER_PORT: '; ss -Htn state established dst $IRAN_IP:$CARRIER_PORT 2>/dev/null | wc -l
   ;;
 logs)
   grep -hEi 'error|timeout|closed|failed|pool is full' $LOG_DIR/frpc-*.log 2>/dev/null | tail -120 || true
   ;;
 *) echo 'Usage: frp-shardctl {status|logs}' >&2; exit 2;;
esac
EOF_CTL
  chmod 0755 /usr/local/bin/frp-shardctl
}

install_iran(){
  [[ -n "$IRAN_IP" && -n "$DOMAIN" ]] || die "--iran-ip and --domain are required"
  valid_ip "$IRAN_IP" || die "invalid --iran-ip"
  valid_domain "$DOMAIN" || die "invalid --domain"

  for p in 443 "$CARRIER_PORT" "$TEST_PORT" "$FRPS_PORT" "$PROXY_PORT"; do
    port_busy "$p" && die "TCP port $p is already in use; refusing to overwrite a live service"
  done

  local dns_ips
  dns_ips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  echo "$dns_ips" | grep -Fxq "$IRAN_IP" || die "$DOMAIN does not currently resolve to $IRAN_IP"

  install_base_deps
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq haproxy nginx certbot
  systemctl stop nginx haproxy 2>/dev/null || true
  install_frp
  maybe_open_ufw_iran
  issue_cert

  local bak="/root/frp-sharded-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$bak"
  backup_file /etc/nginx/nginx.conf "$bak/nginx.conf"
  backup_file /etc/nginx/conf.d/frp-sharded.conf "$bak/frp-sharded.conf"
  backup_file /etc/haproxy/haproxy.cfg "$bak/haproxy.cfg"

  tune_nginx
  write_frps
  write_nginx
  write_haproxy
  write_iran_ctl
  make_bundle

  nginx -t
  haproxy -c -f /etc/haproxy/haproxy.cfg

  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/frp-sharded-nginx <<'HOOK'
#!/usr/bin/env bash
systemctl reload nginx
HOOK
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/frp-sharded-nginx

  systemctl daemon-reload
  systemctl enable --now frps-sharded >/dev/null
  systemctl enable --now nginx >/dev/null
  systemctl enable --now haproxy >/dev/null
  sleep 2

  systemctl is-active --quiet frps-sharded || die "frps-sharded failed"
  systemctl is-active --quiet nginx || die "nginx failed"
  systemctl is-active --quiet haproxy || die "haproxy failed"

  log "Fresh Iran 16-shard FRP edge installed"
  echo "[+] Foreign bundle: $BUNDLE_OUT"
  echo "[+] User endpoint: $IRAN_IP:443"
  echo "[+] Test endpoint: $IRAN_IP:$TEST_PORT"
  echo "[+] Carrier endpoint: $DOMAIN:$CARRIER_PORT"
  echo "[i] User proxy stays DOWN until Foreign shards connect."
  frp-shardctl status
}

install_foreign(){
  install_base_deps
  load_bundle
  timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null || die "Xray is not listening on 127.0.0.1:443; nothing changed"
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || die "system CA bundle missing"

  install_frp
  write_foreign_configs
  write_foreign_ctl

  systemctl daemon-reload
  for i in $(seq -w 1 "$SHARDS"); do systemctl enable --now "frpc-shard@$i" >/dev/null; done

  local ok=0 active
  for _ in {1..30}; do
    active=0
    for i in $(seq -w 1 "$SHARDS"); do systemctl is-active --quiet "frpc-shard@$i" && active=$((active+1)); done
    if [[ "$active" -eq "$SHARDS" ]] && grep -Rqs 'start proxy success' "$LOG_DIR"/frpc-*.log; then ok=1; break; fi
    sleep 1
  done
  ((ok==1)) || { frp-shardctl status; frp-shardctl logs; die "not all shards became ready"; }

  log "Foreign 16-shard FRP mux installed; existing Xray/3x-ui was preserved"
  frp-shardctl status
}

case "$ROLE" in
  iran) install_iran;;
  foreign) install_foreign;;
esac

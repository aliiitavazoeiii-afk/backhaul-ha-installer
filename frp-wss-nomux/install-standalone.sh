#!/usr/bin/env bash
set -Eeuo pipefail

FRP_VERSION="0.70.1"
FRP_DIR="/opt/frp-nomux"
CFG_DIR="/etc/frp-nomux"
LOG_DIR="/var/log/frp-nomux"
TOKEN_FILE="$CFG_DIR/token"
BUNDLE_OUT="/root/frp-nomux.env"
FRPS_PORT=18081
PROXY_PORT=10445
TEST_PORT=2443
POOL_COUNT=20
MAX_POOL_COUNT=50

ROLE=""; IRAN_IP=""; DOMAIN=""; BUNDLE=""
log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

usage(){ cat <<'EOF'
IRAN:
  bash install-standalone.sh --role iran --iran-ip 185.215.230.204 --domain aeg.biya2film.top
FOREIGN:
  bash install-standalone.sh --role foreign --bundle /root/frp-nomux.env
EOF
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

write_unit(){
  local service="$1" bin="$2" cfg="$3"
  cat >"/etc/systemd/system/${service}.service" <<EOF
[Unit]
Description=FRP WSS no-mux ${service}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$FRP_DIR/bin/$bin -c $CFG_DIR/$cfg
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
EOF
}

write_frps(){
  cat >"$CFG_DIR/frps.toml" <<EOF
bindAddr = "127.0.0.1"
bindPort = $FRPS_PORT
proxyBindAddr = "127.0.0.1"
transport.maxPoolCount = $MAX_POOL_COUNT
transport.tcpMux = false
transport.tcpKeepalive = 30
transport.tls.force = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$TOKEN_FILE"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

allowPorts = [{ single = $PROXY_PORT }]
maxPortsPerClient = 1
userConnTimeout = 10

log.to = "$LOG_DIR/frps.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true
EOF
  chmod 0600 "$CFG_DIR/frps.toml"
}

write_frpc(){
  cat >"$CFG_DIR/frpc.toml" <<EOF
clientID = "frp-nomux-primary"
serverAddr = "$IRAN_IP"
serverPort = 443
loginFailExit = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$TOKEN_FILE"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

transport.protocol = "wss"
transport.tcpMux = false
transport.poolCount = $POOL_COUNT
transport.dialServerTimeout = 8
transport.dialServerKeepalive = 30
transport.tls.enable = true
transport.tls.serverName = "$DOMAIN"
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
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 2
healthCheck.maxFailed = 5
healthCheck.intervalSeconds = 2
EOF
  chmod 0600 "$CFG_DIR/frpc.toml"
}

write_iran_nginx(){
  rm -f /etc/nginx/sites-enabled/default
  cat >/etc/nginx/conf.d/frp-nomux.conf <<EOF
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
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_pass http://127.0.0.1:$FRPS_PORT;
    }

    location / { return 404; }
}
EOF
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

write_haproxy(){
  cat >/etc/haproxy/haproxy.cfg <<EOF
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

frontend public_443
    bind *:443
    mode tcp
    tcp-request inspect-delay 3s
    tcp-request content accept if { req_ssl_hello_type 1 }
    acl frp_carrier req.ssl_sni -i $DOMAIN
    use_backend frp_carrier_tls if frp_carrier
    default_backend frp_user_gateway

backend frp_carrier_tls
    mode tcp
    server local_nginx 127.0.0.1:9443 check inter 2s fall 3 rise 2

backend frp_user_gateway
    mode tcp
    option redispatch
    retries 2
    server frp_user 127.0.0.1:$PROXY_PORT check inter 1s fall 2 rise 2

frontend frp_test_$TEST_PORT
    bind *:$TEST_PORT
    mode tcp
    default_backend frp_user_gateway
EOF
  # normalize accidental leading space before defaults (HAProxy accepts it, but keep file clean)
  sed -i 's/^ defaults$/defaults/' /etc/haproxy/haproxy.cfg
}

write_frpctl_iran(){
  cat >/usr/local/bin/frpctl <<EOF
#!/usr/bin/env bash
set -u
case "\${1:-status}" in
  status)
    echo '=== FRPS ==='; systemctl is-active frps-nomux || true
    echo '=== NGINX ==='; systemctl is-active nginx || true
    echo '=== HAPROXY ==='; systemctl is-active haproxy || true
    echo '=== FRP USER PROXY ==='; ss -Hlnpt | grep -q '127.0.0.1:$PROXY_PORT ' && echo UP || echo DOWN
    echo '=== PUBLIC ==='; ss -Hlnpt | grep -E ':(443|$TEST_PORT) ' || true
    ;;
  logs) tail -n 120 '$LOG_DIR/frps.log' 2>/dev/null || true;;
  *) echo 'Usage: frpctl {status|logs}' >&2; exit 2;;
esac
EOF
  chmod 0755 /usr/local/bin/frpctl
}

write_frpctl_foreign(){
  cat >/usr/local/bin/frpctl <<EOF
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
EOF
  chmod 0755 /usr/local/bin/frpctl
}

maybe_open_ufw(){
  command -v ufw >/dev/null || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
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

install_iran(){
  [[ -n "$IRAN_IP" && -n "$DOMAIN" ]] || die "--iran-ip and --domain are required"
  valid_ip "$IRAN_IP" || die "invalid --iran-ip"
  valid_domain "$DOMAIN" || die "invalid --domain"

  for p in 443 9443 "$FRPS_PORT" "$PROXY_PORT" "$TEST_PORT"; do
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

  nginx -t
  haproxy -c -f /etc/haproxy/haproxy.cfg

  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/frp-nomux-nginx <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/frp-nomux-nginx

  umask 077
  cat >"$BUNDLE_OUT" <<EOF
ROLE='foreign'
IRAN_IP='$IRAN_IP'
DOMAIN='$DOMAIN'
TOKEN='$(cat "$TOKEN_FILE")'
FRP_VERSION='$FRP_VERSION'
EOF
  chmod 0600 "$BUNDLE_OUT"

  systemctl daemon-reload
  systemctl enable --now frps-nomux >/dev/null
  systemctl enable --now nginx >/dev/null
  systemctl enable --now haproxy >/dev/null
  sleep 2
  systemctl is-active --quiet frps-nomux || die "frps-nomux failed"
  systemctl is-active --quiet nginx || die "nginx failed"
  systemctl is-active --quiet haproxy || die "haproxy failed"

  log "Standalone Iran side installed"
  echo "[+] Bundle: $BUNDLE_OUT"
  echo "[+] User endpoint: $IRAN_IP:443"
  echo "[+] Test endpoint: $IRAN_IP:$TEST_PORT"
  echo "[i] FRP USER PROXY will stay DOWN until Foreign frpc connects."
  frpctl status
}

load_bundle(){
  [[ -n "$BUNDLE" && -f "$BUNDLE" ]] || die "--bundle file required"
  # shellcheck disable=SC1090
  source "$BUNDLE"
  [[ "${ROLE:-}" == foreign ]] || die "invalid bundle role"
  valid_ip "$IRAN_IP" || die "invalid IRAN_IP in bundle"
  valid_domain "$DOMAIN" || die "invalid DOMAIN in bundle"
  [[ "${TOKEN:-}" =~ ^[0-9a-f]{64}$ ]] || die "invalid token in bundle"
  [[ "${FRP_VERSION:-}" == "0.70.1" ]] || die "unexpected FRP version in bundle"
}

install_foreign(){
  load_bundle
  timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null || die "Xray is not listening on 127.0.0.1:443; nothing changed"

  install_base_deps
  install_frp
  umask 077
  printf '%s\n' "$TOKEN" >"$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"
  write_frpc
  write_unit frpc-nomux frpc frpc.toml
  write_frpctl_foreign

  systemctl daemon-reload
  systemctl enable --now frpc-nomux >/dev/null

  local ok=0
  for _ in {1..20}; do
    if grep -Eq 'start proxy success|login to server success' "$LOG_DIR/frpc.log" 2>/dev/null; then ok=1; break; fi
    sleep 1
  done
  if ((ok == 0)); then
    tail -n 80 "$LOG_DIR/frpc.log" 2>/dev/null || true
    die "frpc started but did not register successfully"
  fi

  log "Foreign FRP WSS no-mux installed; existing Xray/3x-ui preserved"
  frpctl status
}

case "$ROLE" in
  iran) install_iran;;
  foreign) install_foreign;;
esac

#!/usr/bin/env bash
set -Eeuo pipefail

APP="frp-tunnel-ali-shared"
BRAND="FRP Tunnel — Ali Shared Hub"
VERSION="1.0.0"
FRP_VERSION="0.71.0"
FRP_AMD64_SHA256="84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716"
FRP_ARM64_SHA256="f33c293c275d8fc68c654b6fba8f10b2551d6463d09a9fc9cffb7227eae82266"
ETC="/etc/${APP}"
OPT="/opt/${APP}"
BIN="${OPT}/bin"
STATE="/var/lib/${APP}"
SERVICE="${APP}.service"
EDGE_SERVICE="${APP}-edge.service"
NGINX_CONF="/etc/nginx/conf.d/${APP}.conf"
NGINX_LIMIT_DROPIN="/etc/systemd/system/nginx.service.d/${APP}-limits.conf"
ACME_ROOT="/var/www/frp-ali-shared-acme"
MAYA1_PORT=14431
MAYA3_PORT=14433
PUBLIC_PORT=443

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
cyan(){ printf '\033[36m%s\033[0m\n' "$*"; }
die(){ red "ERROR: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
valid_ipv4(){ local IFS=. a b c d e; read -r a b c d e <<<"$1"; [[ -z ${e:-} && $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1; ((10#$a<=255 && 10#$b<=255 && 10#$c<=255 && 10#$d<=255)); }
valid_domain(){ [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
prompt(){ local var="$1" text="$2" def="${3:-}" val; if [[ -n "$def" ]]; then read -r -p "$text [$def]: " val; val="${val:-$def}"; else read -r -p "$text: " val; fi; printf -v "$var" '%s' "$val"; }
prompt_secret(){ local var="$1" text="$2" val; read -r -s -p "$text: " val; echo; printf -v "$var" '%s' "$val"; }

banner(){
  cat <<EOF
==============================================================
 ${BRAND} v${VERSION}
 WSS/TLS · FRP v${FRP_VERSION} · tcpMux off · 4 shards/slot
 Shared Iran :443 selector for MAYA1 / MAYA3
==============================================================
EOF
}

install_common_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y ca-certificates curl tar openssl jq iproute2 netcat-openbsd >/dev/null
}
install_iran_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y nginx certbot haproxy socat >/dev/null
}

resolve_contains(){
  local domain="$1" ip="$2"
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | grep -Fxq "$ip"
}

port_busy(){ ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }
require_port_free(){
  local p="$1" owner
  port_busy "$p" || return 0
  owner="$(ss -H -ltnp "sport = :$p" 2>/dev/null | head -n1 || true)"
  die "TCP port $p is already in use: $owner"
}

download_frp(){
  mkdir -p "$BIN"
  local arch pkg sha tmp url dir
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) pkg="frp_${FRP_VERSION}_linux_amd64.tar.gz"; sha="$FRP_AMD64_SHA256" ;;
    aarch64|arm64) pkg="frp_${FRP_VERSION}_linux_arm64.tar.gz"; sha="$FRP_ARM64_SHA256" ;;
    *) die "Unsupported architecture: $arch" ;;
  esac
  tmp="$(mktemp -d)"
  url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${pkg}"
  cyan "Downloading pinned FRP v${FRP_VERSION}..."
  curl -fL --retry 4 --connect-timeout 15 "$url" -o "$tmp/$pkg"
  echo "$sha  $tmp/$pkg" | sha256sum -c - >/dev/null || { rm -rf "$tmp"; die "FRP checksum mismatch."; }
  tar -xzf "$tmp/$pkg" -C "$tmp"
  dir="$tmp/${pkg%.tar.gz}"
  install -m 0755 "$dir/frps" "$BIN/frps"
  install -m 0755 "$dir/frpc" "$BIN/frpc"
  rm -rf "$tmp"
}

backup_existing(){
  mkdir -p "$STATE/backups"
  chmod 0700 "$STATE" "$STATE/backups"
  local ts="$(date +%Y%m%d-%H%M%S)"
  [[ -d "$ETC" ]] && tar -C / -czf "$STATE/backups/etc-${ts}.tar.gz" "${ETC#/}" || true
  [[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$STATE/backups/nginx-${ts}.conf" || true
}

nginx_capacity(){
  mkdir -p "$(dirname "$NGINX_LIMIT_DROPIN")" "$STATE/backups"
  cat >"$NGINX_LIMIT_DROPIN" <<EOF
[Service]
LimitNOFILE=262144
EOF
  local bak="$STATE/backups/nginx.conf.$(date +%Y%m%d-%H%M%S)"
  cp -a /etc/nginx/nginx.conf "$bak"
  if grep -Eq '^[[:space:]]*worker_connections[[:space:]]+[0-9]+' /etc/nginx/nginx.conf; then
    sed -ri 's/^[[:space:]]*worker_connections[[:space:]]+[0-9]+;/        worker_connections 65535;/' /etc/nginx/nginx.conf
  else
    sed -ri '/^[[:space:]]*events[[:space:]]*\{/a\        worker_connections 65535;' /etc/nginx/nginx.conf
  fi
  grep -Eq '^[[:space:]]*worker_rlimit_nofile' /etc/nginx/nginx.conf || sed -ri '/^[[:space:]]*worker_processes/a worker_rlimit_nofile 262144;' /etc/nginx/nginx.conf
  if ! nginx -t >/dev/null 2>&1; then
    cp -a "$bak" /etc/nginx/nginx.conf
    nginx -t >/dev/null 2>&1 || die "nginx.conf was invalid before capacity tuning."
    die "Nginx capacity tuning failed and was rolled back."
  fi
  systemctl daemon-reload
}

write_acme_nginx(){
  mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
  cat >"/etc/nginx/conf.d/${APP}-acme.conf" <<EOF
server {
    listen ${IRAN_IP}:80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ { root ${ACME_ROOT}; }
    location / { return 404; }
}
EOF
}

ensure_certificate(){
  local cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  local key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  if [[ -s "$cert" && -s "$key" ]] && openssl x509 -in "$cert" -checkhost "$DOMAIN" -checkend 604800 -noout >/dev/null 2>&1; then
    green "Using existing valid Let's Encrypt certificate."
    return 0
  fi
  write_acme_nginx
  nginx -t || die "Temporary ACME nginx config is invalid."
  systemctl enable --now nginx >/dev/null
  systemctl reload nginx
  certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --agree-tos --non-interactive --register-unsafely-without-email || die "Let's Encrypt issuance failed. DNS must point directly to ${IRAN_IP}, and TCP/80 must be reachable."
}

write_nginx(){
  rm -f "/etc/nginx/conf.d/${APP}-acme.conf"
  mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
  cat >"$NGINX_CONF" <<EOF
# ${BRAND}
server {
    listen ${IRAN_IP}:80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ { root ${ACME_ROOT}; }
    location / { return 404; }
}
server {
    listen ${IRAN_IP}:${CONTROL_PORT} ssl;
    server_name ${DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:FRPALISHARED:20m;
    ssl_session_timeout 1d;
    server_tokens off;
    tcp_nodelay on;
    location = /~!frp {
        if (\$http_upgrade !~* "websocket") { return 404; }
        proxy_pass http://127.0.0.1:18443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_connect_timeout 10s;
        proxy_buffering off;
        proxy_request_buffering off;
    }
    location / { return 404; }
}
EOF
}

write_frps(){
  cat >"$ETC/frps.toml" <<EOF
bindAddr = "127.0.0.1"
bindPort = 18443
proxyBindAddr = "127.0.0.1"

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "${ETC}/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

transport.tcpMux = false
transport.tcpKeepalive = 30
transport.maxPoolCount = 64
transport.heartbeatTimeout = 90

allowPorts = [{ single = ${MAYA1_PORT} }, { single = ${MAYA3_PORT} }]
maxPortsPerClient = 8
userConnTimeout = 10
detailedErrorsToClient = false

webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.pprofEnable = false
log.to = "console"
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true
EOF
}

write_systemd_iran(){
  cat >"/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=${BRAND} - Iran FRPS
After=network-online.target nginx.service
Wants=network-online.target
Requires=nginx.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=${BIN}/frps verify -c ${ETC}/frps.toml
ExecStart=${BIN}/frps -c ${ETC}/frps.toml
Restart=always
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=20
LimitNOFILE=1048576
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
[Install]
WantedBy=multi-user.target
EOF
}

write_haproxy(){
  cat >"$ETC/haproxy.cfg" <<EOF
global
    maxconn 100000
    stats socket /run/${APP}/admin.sock mode 600 level admin
    log stdout format raw local0

defaults
    mode tcp
    log global
    option tcplog
    option tcpka
    timeout connect 10s
    timeout client  1h
    timeout server  1h

frontend vpn_public
    bind ${IRAN_IP}:${PUBLIC_PORT}
    default_backend maya_slots

backend maya_slots
    balance first
    option tcp-check
    server maya1 127.0.0.1:${MAYA1_PORT} check inter 3s fall 2 rise 2
    server maya3 127.0.0.1:${MAYA3_PORT} check inter 3s fall 2 rise 2 disabled
EOF
  /usr/sbin/haproxy -c -f "$ETC/haproxy.cfg" >/dev/null || die "HAProxy validation failed."
  cat >"/etc/systemd/system/${EDGE_SERVICE}" <<EOF
[Unit]
Description=${BRAND} - public slot selector edge
After=network-online.target ${SERVICE}
Wants=network-online.target
Requires=${SERVICE}
[Service]
Type=notify
ExecStart=/usr/sbin/haproxy -Ws -f ${ETC}/haproxy.cfg -p /run/${APP}/haproxy.pid
ExecStartPost=/usr/local/bin/frp-shared-select restore
ExecReload=/usr/sbin/haproxy -c -f ${ETC}/haproxy.cfg
Restart=always
RestartSec=2
RuntimeDirectory=${APP}
RuntimeDirectoryMode=0700
LimitNOFILE=262144
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
}

write_selector(){
  cat >"/usr/local/bin/frp-shared-select" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP=frp-tunnel-ali-shared
ETC=/etc/$APP
STATE=/var/lib/$APP
SOCK=/run/$APP/admin.sock
mkdir -p "$STATE"
slot="${1:-status}"
if [[ "$slot" == restore ]]; then
  slot="$(cat "$STATE/selected-slot" 2>/dev/null || echo maya1)"
fi
case "$slot" in
  maya1) port=14431; other=maya3 ;;
  maya3) port=14433; other=maya1 ;;
  status)
    echo "selected=$(cat "$STATE/selected-slot" 2>/dev/null || echo unknown)"
    [[ -S "$SOCK" ]] && printf 'show stat\n' | socat - UNIX-CONNECT:"$SOCK" | grep -E 'maya_slots,(maya1|maya3),' || true
    exit 0 ;;
  *) echo "Usage: frp-shared-select {maya1|maya3|status|restore}" >&2; exit 2 ;;
esac
for _ in {1..30}; do [[ -S "$SOCK" ]] && break; sleep 0.2; done
[[ -S "$SOCK" ]] || { echo "HAProxy runtime socket unavailable" >&2; exit 1; }
if ! nc -z -w2 127.0.0.1 "$port"; then
  echo "Refusing switch: $slot FRP backend 127.0.0.1:$port is not listening" >&2
  exit 1
fi
{
  echo "disable server maya_slots/$other"
  echo "enable server maya_slots/$slot"
} | socat - UNIX-CONNECT:"$SOCK" >/dev/null
printf '%s\n' "$slot" >"$STATE/selected-slot"
chmod 0600 "$STATE/selected-slot"
echo "Selected $slot -> local FRP port $port"
EOF
  chmod 0755 /usr/local/bin/frp-shared-select

  cat >"/usr/local/bin/frp-shared-reconcile" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
hour="$(TZ=Asia/Tehran date +%H)"
hour=$((10#$hour))
if (( hour >= 12 && hour < 18 )); then desired=maya3; else desired=maya1; fi
current="$(cat /var/lib/frp-tunnel-ali-shared/selected-slot 2>/dev/null || true)"
[[ "$current" == "$desired" ]] && exit 0
/usr/local/bin/frp-shared-select "$desired"
EOF
  chmod 0755 /usr/local/bin/frp-shared-reconcile

  cat >"/etc/systemd/system/${APP}-reconcile.service" <<EOF
[Unit]
Description=${BRAND} - reconcile scheduled slot
After=${EDGE_SERVICE}
[Service]
Type=oneshot
ExecStart=/usr/local/bin/frp-shared-reconcile
EOF
  cat >"/etc/systemd/system/${APP}-reconcile.timer" <<EOF
[Unit]
Description=${BRAND} - schedule MAYA3 12-18, MAYA1 18-24 Tehran
[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true
Unit=${APP}-reconcile.service
[Install]
WantedBy=timers.target
EOF
}

make_pair(){
  local slot="$1" expected_ip="$2" remote_port group_key token payload out
  token="$(cat "$ETC/token")"
  group_key="$(openssl rand -hex 32)"
  out="$ETC/pair-${slot}.txt"
  payload="$(jq -cn \
    --arg iran "$IRAN_IP" --arg domain "$DOMAIN" --arg cp "$CONTROL_PORT" \
    --arg slot "$slot" --arg rp "$remote_port" --arg token "$token" \
    --arg group_key "$group_key" --arg foreign "$expected_ip" \
    '{v:1,mode:"ali-shared",iran:$iran,domain:$domain,control_port:$cp,slot:$slot,remote_port:$rp,token:$token,group_key:$group_key,expected_foreign_ip:$foreign}')"
  printf '%s' "$payload" | base64 -w0 >"$out"
  chmod 0600 "$out"
}

decode_pair(){
  local json
  json="$(printf '%s' "$PAIR_CODE" | base64 -d 2>/dev/null)" || die "Invalid pair code."
  [[ "$(jq -r '.v // empty' <<<"$json")" == "1" ]] || die "Unsupported pair code version."
  [[ "$(jq -r '.mode // empty' <<<"$json")" == "ali-shared" ]] || die "Pair code is not for Ali Shared Hub."
  IRAN_IP="$(jq -r '.iran' <<<"$json")"
  DOMAIN="$(jq -r '.domain' <<<"$json")"
  CONTROL_PORT="$(jq -r '.control_port' <<<"$json")"
  SLOT="$(jq -r '.slot' <<<"$json")"
  REMOTE_PORT="$(jq -r '.remote_port' <<<"$json")"
  TOKEN="$(jq -r '.token' <<<"$json")"
  GROUP_KEY="$(jq -r '.group_key' <<<"$json")"
  EXPECTED_FOREIGN_IP="$(jq -r '.expected_foreign_ip // empty' <<<"$json")"
  valid_ipv4 "$IRAN_IP" || die "Bad Iran IP in pair code."
  valid_domain "$DOMAIN" || die "Bad domain in pair code."
  valid_port "$CONTROL_PORT" || die "Bad control port in pair code."
  valid_port "$REMOTE_PORT" || die "Bad remote port in pair code."
  [[ "$SLOT" == maya1 || "$SLOT" == maya3 ]] || die "Bad slot in pair code."
  [[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] || die "Bad auth token in pair code."
  [[ "$GROUP_KEY" =~ ^[0-9a-f]{64}$ ]] || die "Bad load-balancer key in pair code."
}

write_frpc_shards(){
  local shard dashboard
  for shard in 01 02 03 04; do
    case "$shard" in 01) dashboard=7401;; 02) dashboard=7402;; 03) dashboard=7403;; 04) dashboard=7404;; esac
    cat >"$ETC/frpc-${shard}.toml" <<EOF
clientID = "ali-shared-${SLOT}-${shard}"
serverAddr = "${DOMAIN}"
serverPort = ${CONTROL_PORT}
loginFailExit = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "${ETC}/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

transport.protocol = "wss"
transport.tls.enable = true
transport.tls.serverName = "${DOMAIN}"
transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"
transport.tls.disableCustomTLSFirstByte = true
transport.tcpMux = false
transport.poolCount = 6
transport.dialServerTimeout = 10
transport.dialServerKeepalive = 30
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 90
transport.wireProtocol = "v1"

webServer.addr = "127.0.0.1"
webServer.port = ${dashboard}
webServer.pprofEnable = false
log.to = "console"
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true

[[proxies]]
name = "ali-shared-${SLOT}-${shard}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_PORT}
remotePort = ${REMOTE_PORT}
transport.useEncryption = false
transport.useCompression = false
loadBalancer.group = "ali-shared-${SLOT}-lb"
loadBalancer.groupKey = "${GROUP_KEY}"
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 3
healthCheck.maxFailed = 5
healthCheck.intervalSeconds = 5
EOF
  done
}

write_systemd_foreign(){
  cat >"/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=${BRAND} - Foreign ${SLOT} shard 01
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=${BIN}/frpc verify -c ${ETC}/frpc-01.toml
ExecStart=${BIN}/frpc -c ${ETC}/frpc-01.toml
Restart=always
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=20
LimitNOFILE=1048576
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
[Install]
WantedBy=multi-user.target
EOF
  cat >"/etc/systemd/system/${APP}-shard@.service" <<EOF
[Unit]
Description=${BRAND} - Foreign ${SLOT} shard %i
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=${BIN}/frpc verify -c ${ETC}/frpc-%i.toml
ExecStart=${BIN}/frpc -c ${ETC}/frpc-%i.toml
Restart=always
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=20
LimitNOFILE=1048576
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
[Install]
WantedBy=multi-user.target
EOF
}

write_health(){
  cat >"/usr/local/bin/frp-shared-health" <<'EOF'
#!/usr/bin/env bash
set -u
ETC=/etc/frp-tunnel-ali-shared
[[ -r "$ETC/meta.env" ]] && source "$ETC/meta.env"
echo "=== FRP Ali Shared Hub ==="
echo "ROLE=${ROLE:-unknown} SLOT=${SLOT:-n/a} DOMAIN=${DOMAIN:-unknown}"
if [[ ${ROLE:-} == iran ]]; then
  for u in frp-tunnel-ali-shared frp-tunnel-ali-shared-edge frp-tunnel-ali-shared-reconcile.timer; do printf '%-42s ' "$u"; systemctl is-active "$u" || true; done
  /usr/local/bin/frp-shared-select status || true
  ss -lntp | grep -E ':443|:8443|:18443|:14431|:14433' || true
else
  for u in frp-tunnel-ali-shared frp-tunnel-ali-shared-shard@02 frp-tunnel-ali-shared-shard@03 frp-tunnel-ali-shared-shard@04; do printf '%-42s ' "$u"; systemctl is-active "$u" || true; done
  nc -z -w3 127.0.0.1 "${LOCAL_PORT:-443}" && echo "local Xray: OK" || echo "local Xray: FAIL"
fi
EOF
  chmod 0755 /usr/local/bin/frp-shared-health
}

write_meta(){
  cat >"$ETC/meta.env" <<EOF
ROLE=${ROLE}
IRAN_IP=${IRAN_IP}
DOMAIN=${DOMAIN}
CONTROL_PORT=${CONTROL_PORT}
SLOT=${SLOT:-}
REMOTE_PORT=${REMOTE_PORT:-}
LOCAL_PORT=${LOCAL_PORT:-}
VERSION=${VERSION}
EOF
  chmod 0600 "$ETC/meta.env"
}

install_iran(){
  ROLE=iran
  prompt IRAN_IP "Iran shared public IPv4" "5.10.249.206"
  prompt DOMAIN "Shared FRP control domain (DNS-only A -> Iran IP)"
  prompt CONTROL_PORT "WSS control port" "8443"
  prompt MAYA1_FOREIGN_IP "MAYA1 Foreign IPv4" "193.57.9.31"
  prompt MAYA3_FOREIGN_IP "MAYA3 Foreign IPv4" "193.57.9.167"
  valid_ipv4 "$IRAN_IP" || die "Invalid Iran IPv4."
  valid_ipv4 "$MAYA1_FOREIGN_IP" || die "Invalid MAYA1 Foreign IPv4."
  valid_ipv4 "$MAYA3_FOREIGN_IP" || die "Invalid MAYA3 Foreign IPv4."
  valid_domain "$DOMAIN" || die "Invalid domain."
  valid_port "$CONTROL_PORT" || die "Invalid control port."
  [[ "$CONTROL_PORT" != "$PUBLIC_PORT" ]] || die "Control and public ports must differ."
  resolve_contains "$DOMAIN" "$IRAN_IP" || die "DNS for $DOMAIN must resolve directly to $IRAN_IP before installation."

  install_common_deps
  install_iran_deps
  mkdir -p "$ETC" "$OPT" "$STATE"
  chmod 0700 "$ETC" "$STATE"
  backup_existing
  require_port_free "$PUBLIC_PORT"
  require_port_free "$CONTROL_PORT"
  download_frp

  openssl rand -hex 32 >"$ETC/token"
  chmod 0600 "$ETC/token"
  write_frps
  "$BIN/frps" verify -c "$ETC/frps.toml" || die "FRPS validation failed."
  write_systemd_iran
  nginx_capacity
  ensure_certificate
  write_nginx
  nginx -t || die "Final nginx config is invalid."

  # The package's default HAProxy service is not used; the project has an isolated service/config.
  if systemctl is-active --quiet haproxy.service; then
    if ss -H -ltnp 2>/dev/null | grep -q 'haproxy'; then
      die "System haproxy.service already owns listeners. Refusing to disrupt it."
    fi
    systemctl disable --now haproxy.service >/dev/null 2>&1 || true
  else
    systemctl disable haproxy.service >/dev/null 2>&1 || true
  fi

  write_haproxy
  write_selector
  make_pair maya1 "$MAYA1_FOREIGN_IP" "$MAYA1_PORT"
  make_pair maya3 "$MAYA3_FOREIGN_IP" "$MAYA3_PORT"
  write_meta
  write_health

  # Select a sane default; reconcile will enforce the Tehran schedule once backends register.
  hour="$(TZ=Asia/Tehran date +%H)"; hour=$((10#$hour))
  if (( hour >= 12 && hour < 18 )); then echo maya3 >"$STATE/selected-slot"; else echo maya1 >"$STATE/selected-slot"; fi
  chmod 0600 "$STATE/selected-slot"

  systemctl daemon-reload
  systemctl enable --now nginx >/dev/null
  systemctl reload nginx
  systemctl enable --now "$SERVICE" >/dev/null
  sleep 2
  systemctl is-active --quiet "$SERVICE" || { journalctl -u "$SERVICE" -n 80 --no-pager; die "FRPS failed to start."; }
  systemctl enable --now "$EDGE_SERVICE" >/dev/null
  sleep 2
  systemctl is-active --quiet "$EDGE_SERVICE" || { journalctl -u "$EDGE_SERVICE" -n 80 --no-pager; die "Shared public edge failed to start."; }
  systemctl enable --now "${APP}-reconcile.timer" >/dev/null

  green "IRAN SHARED HUB READY."
  echo
  echo "MAYA1 PAIR CODE (secret):"
  cat "$ETC/pair-maya1.txt"; echo
  echo
  echo "MAYA3 PAIR CODE (secret):"
  cat "$ETC/pair-maya3.txt"; echo
  echo
  echo "After both Foreign installs: frp-shared-health"
}

install_foreign(){
  ROLE=foreign
  install_common_deps
  if [[ -z ${PAIR_CODE:-} ]]; then prompt_secret PAIR_CODE "Paste Shared Hub pair code"; fi
  decode_pair
  if [[ -n ${2:-} && "$2" != "$SLOT" ]]; then die "Pair code belongs to $SLOT, not $2."; fi
  prompt LOCAL_PORT "Existing local Xray/3x-ui inbound port" "443"
  valid_port "$LOCAL_PORT" || die "Invalid local port."
  mkdir -p "$ETC" "$OPT" "$STATE"
  chmod 0700 "$ETC" "$STATE"
  backup_existing
  download_frp
  nc -z -w3 127.0.0.1 "$LOCAL_PORT" || die "Nothing is listening on 127.0.0.1:${LOCAL_PORT}. Xray/3x-ui was not touched."
  resolve_contains "$DOMAIN" "$IRAN_IP" || die "Control domain does not resolve to shared Iran IP $IRAN_IP."
  curl -fsS --connect-timeout 5 --max-time 10 "https://${DOMAIN}:${CONTROL_PORT}/" -o /dev/null || {
    rc=$?; [[ $rc -eq 22 ]] || die "Cannot complete TLS/HTTP connection to ${DOMAIN}:${CONTROL_PORT}."
  }
  printf '%s\n' "$TOKEN" >"$ETC/token"
  chmod 0600 "$ETC/token"
  write_frpc_shards
  for f in "$ETC"/frpc-*.toml; do "$BIN/frpc" verify -c "$f" || die "FRPC validation failed: $f"; done
  write_systemd_foreign
  write_meta
  write_health
  systemctl daemon-reload
  systemctl enable "$SERVICE" "${APP}-shard@02.service" "${APP}-shard@03.service" "${APP}-shard@04.service" >/dev/null
  systemctl restart "$SERVICE"; sleep 1
  systemctl restart "${APP}-shard@02.service"; sleep 1
  systemctl restart "${APP}-shard@03.service"; sleep 1
  systemctl restart "${APP}-shard@04.service"; sleep 5
  for u in "$SERVICE" "${APP}-shard@02.service" "${APP}-shard@03.service" "${APP}-shard@04.service"; do
    systemctl is-active --quiet "$u" || { journalctl -u "$u" -n 60 --no-pager; die "$u failed."; }
  done
  green "FOREIGN ${SLOT^^} SIDE READY."
  [[ -n "$EXPECTED_FOREIGN_IP" ]] && echo "Expected Foreign metadata: $EXPECTED_FOREIGN_IP"
  echo "Shared Iran remote slot: 127.0.0.1:${REMOTE_PORT} behind public ${IRAN_IP}:443"
  echo "Health: frp-shared-health"
}

need_root
banner
case "${1:-}" in
  iran) install_iran ;;
  foreign) install_foreign "$@" ;;
  *) echo "Usage: $0 {iran|foreign}"; exit 2 ;;
esac

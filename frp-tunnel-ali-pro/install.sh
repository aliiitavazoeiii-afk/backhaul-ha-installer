#!/usr/bin/env bash
set -Eeuo pipefail

APP="frp-tunnel-ali-pro"
BRAND="FRP Tunnel — Ali Pro"
VERSION="1.0.1"
FRP_VERSION="0.71.0"
FRP_AMD64_SHA256="84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716"
FRP_ARM64_SHA256="f33c293c275d8fc68c654b6fba8f10b2551d6463d09a9fc9cffb7227eae82266"
ETC="/etc/${APP}"
OPT="/opt/${APP}"
BIN="${OPT}/bin"
STATE="/var/lib/${APP}"
SERVICE="${APP}.service"
NGINX_CONF="/etc/nginx/conf.d/${APP}.conf"
NGINX_LIMIT_DROPIN="/etc/systemd/system/nginx.service.d/${APP}-limits.conf"
ACME_ROOT="/var/www/frp-ali-acme"

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
 WSS/TLS edge · FRP v${FRP_VERSION} · tcpMux off · 4 shards
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
  apt-get install -y nginx certbot >/dev/null
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
  trap 'rm -rf "$tmp"' RETURN
  url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${pkg}"
  cyan "Downloading pinned FRP v${FRP_VERSION}..."
  curl -fL --retry 4 --connect-timeout 15 "$url" -o "$tmp/$pkg"
  echo "$sha  $tmp/$pkg" | sha256sum -c - >/dev/null || die "FRP checksum mismatch."
  tar -xzf "$tmp/$pkg" -C "$tmp"
  dir="$tmp/${pkg%.tar.gz}"
  install -m 0755 "$dir/frps" "$BIN/frps"
  install -m 0755 "$dir/frpc" "$BIN/frpc"
  rm -rf "$tmp"
  trap - RETURN
}

backup_existing(){
  mkdir -p "$STATE/backups"
  chmod 0700 "$STATE" "$STATE/backups"
  local ts="$(date +%Y%m%d-%H%M%S)"
  [[ -d "$ETC" ]] && tar -C / -czf "$STATE/backups/etc-${ts}.tar.gz" "${ETC#/}" || true
  [[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$STATE/backups/nginx-${ts}.conf" || true
}

port_busy(){ ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }

port_owned_by_our_service(){
  local p="$1" pid owner
  systemctl is-active --quiet "$SERVICE" || return 1
  pid="$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
  owner="$(ss -H -ltnp "sport = :$p" 2>/dev/null | head -n1 || true)"
  [[ "$owner" == *"pid=$pid,"* ]]
}

require_port_free_or_ours(){
  local p="$1" owner
  port_busy "$p" || return 0
  port_owned_by_our_service "$p" && return 0
  owner="$(ss -H -ltnp "sport = :$p" 2>/dev/null | head -n1 || true)"
  die "TCP port $p is already owned by another service: $owner"
}

resolve_contains(){
  local domain="$1" ip="$2"
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | grep -Fxq "$ip"
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

write_systemd_foreign(){
cat >"/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=${BRAND} - Foreign FRPC shard 01
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
Description=${BRAND} - Foreign FRPC shard %i
After=network-online.target ${SERVICE}
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
    die "Nginx capacity tuning failed validation and was rolled back."
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
  certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --agree-tos --non-interactive --register-unsafely-without-email || die "Let's Encrypt issuance failed. Make sure DNS points directly to this Iran IP and TCP/80 is reachable."
}

write_nginx(){
  rm -f "/etc/nginx/conf.d/${APP}-acme.conf"
  mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
  cat >"$NGINX_CONF" <<EOF
# ${BRAND}
# Port 80 is retained only for ACME renewal. FRP control is WSS/TLS on ${CONTROL_PORT}.
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
    ssl_session_cache shared:FRPALIPRO:20m;
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
proxyBindAddr = "${IRAN_IP}"

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "${ETC}/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

transport.tcpMux = false
transport.tcpKeepalive = 30
transport.maxPoolCount = 64
transport.heartbeatTimeout = 90

allowPorts = [{ single = ${PUBLIC_PORT} }]
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

make_pair(){
  local token payload
  token="$(cat "$ETC/token")"
  payload="$(jq -cn --arg iran "$IRAN_IP" --arg foreign "$FOREIGN_IP" --arg domain "$DOMAIN" --arg cp "$CONTROL_PORT" --arg pp "$PUBLIC_PORT" --arg token "$token" --arg profile "$PROFILE" '{v:3,iran:$iran,foreign:$foreign,domain:$domain,control_port:$cp,public_port:$pp,token:$token,profile:$profile}')"
  printf '%s' "$payload" | base64 -w0 >"$ETC/pair-code.txt"
  chmod 0600 "$ETC/pair-code.txt"
}

decode_pair(){
  local json
  json="$(printf '%s' "$PAIR_CODE" | base64 -d 2>/dev/null)" || die "Invalid pair code."
  [[ "$(jq -r '.v // empty' <<<"$json")" == "3" ]] || die "Unsupported pair code version."
  IRAN_IP="$(jq -r '.iran' <<<"$json")"
  FOREIGN_IP="$(jq -r '.foreign' <<<"$json")"
  DOMAIN="$(jq -r '.domain' <<<"$json")"
  CONTROL_PORT="$(jq -r '.control_port' <<<"$json")"
  PUBLIC_PORT="$(jq -r '.public_port' <<<"$json")"
  TOKEN="$(jq -r '.token' <<<"$json")"
  PROFILE="$(jq -r '.profile' <<<"$json")"
  valid_ipv4 "$IRAN_IP" || die "Bad Iran IP in pair code."
  valid_ipv4 "$FOREIGN_IP" || die "Bad Foreign IP in pair code."
  valid_domain "$DOMAIN" || die "Bad domain in pair code."
  valid_port "$CONTROL_PORT" || die "Bad control port."
  valid_port "$PUBLIC_PORT" || die "Bad public port."
  [[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] || die "Bad token in pair code."
}

write_frpc_shards(){
  local group_key shard port
  group_key="$(openssl rand -hex 32)"
  printf '%s\n' "$group_key" >"$ETC/lb-group-key"
  chmod 0600 "$ETC/lb-group-key"

  for shard in 01 02 03 04; do
    case "$shard" in 01) port=7401;; 02) port=7402;; 03) port=7403;; 04) port=7404;; esac
    cat >"$ETC/frpc-${shard}.toml" <<EOF
clientID = "ali-${PROFILE}-${shard}"
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
webServer.port = ${port}
webServer.pprofEnable = false

log.to = "console"
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true

[[proxies]]
name = "ali-vpn-${PROFILE}-${shard}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_PORT}
remotePort = ${PUBLIC_PORT}
transport.useEncryption = false
transport.useCompression = false
loadBalancer.group = "ali-vpn-${PROFILE}-lb"
loadBalancer.groupKey = "${group_key}"
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 3
healthCheck.maxFailed = 5
healthCheck.intervalSeconds = 5
EOF
  done
}

write_health_cli(){
cat >"/usr/local/bin/frp-ali-health" <<'EOF'
#!/usr/bin/env bash
set -u
ETC=/etc/frp-tunnel-ali-pro
[[ -r "$ETC/meta.env" ]] && source "$ETC/meta.env"
echo "=== FRP Ali Pro ==="
echo "ROLE=${ROLE:-unknown} DOMAIN=${DOMAIN:-unknown}"
if [[ ${ROLE:-} == iran ]]; then
  systemctl is-active frp-tunnel-ali-pro || true
  systemctl is-active nginx || true
  ss -lntp | grep -E ":${CONTROL_PORT:-8443}|:${PUBLIC_PORT:-443}|:18443" || true
  nginx -t 2>&1 || true
  echo "nginx sockets: $(ss -tanp 2>/dev/null | grep -c nginx || true)"
else
  for u in frp-tunnel-ali-pro frp-tunnel-ali-pro-shard@02 frp-tunnel-ali-pro-shard@03 frp-tunnel-ali-pro-shard@04; do printf '%-38s ' "$u"; systemctl is-active "$u" || true; done
  ss -tnp 2>/dev/null | grep frpc | head -n 30 || true
  nc -z -w3 127.0.0.1 "${LOCAL_PORT:-443}" && echo "local Xray: OK" || echo "local Xray: FAIL"
fi
EOF
chmod 0755 /usr/local/bin/frp-ali-health
}

write_meta(){
  cat >"$ETC/meta.env" <<EOF
ROLE=${ROLE}
IRAN_IP=${IRAN_IP}
FOREIGN_IP=${FOREIGN_IP}
DOMAIN=${DOMAIN}
CONTROL_PORT=${CONTROL_PORT}
PUBLIC_PORT=${PUBLIC_PORT}
PROFILE=${PROFILE}
LOCAL_PORT=${LOCAL_PORT:-}
VERSION=${VERSION}
EOF
  chmod 0600 "$ETC/meta.env"
}

install_iran(){
  ROLE=iran
  prompt IRAN_IP "Iran public IPv4"
  prompt FOREIGN_IP "Foreign public IPv4 (may be filtered from Iran)"
  prompt DOMAIN "Tunnel domain (DNS-only A record -> Iran IP)"
  prompt PROFILE "Profile name" "normal"
  prompt CONTROL_PORT "WSS control port" "8443"
  prompt PUBLIC_PORT "Public user port on Iran" "443"
  valid_ipv4 "$IRAN_IP" || die "Invalid Iran IPv4."
  valid_ipv4 "$FOREIGN_IP" || die "Invalid Foreign IPv4."
  valid_domain "$DOMAIN" || die "Invalid domain."
  valid_port "$CONTROL_PORT" || die "Invalid control port."
  valid_port "$PUBLIC_PORT" || die "Invalid public port."
  [[ "$CONTROL_PORT" != "$PUBLIC_PORT" ]] || die "Control and user ports must differ."
  resolve_contains "$DOMAIN" "$IRAN_IP" || die "DNS for $DOMAIN must resolve directly to $IRAN_IP before installation."

  install_common_deps
  install_iran_deps
  mkdir -p "$ETC" "$OPT" "$STATE"
  chmod 0700 "$ETC" "$STATE"
  backup_existing
  download_frp

  require_port_free_or_ours 18443
  require_port_free_or_ours "$PUBLIC_PORT"

  printf '%s\n' "$(openssl rand -hex 32)" >"$ETC/token"
  chmod 0600 "$ETC/token"
  nginx_capacity
  ensure_certificate
  write_nginx
  nginx -t || die "Final nginx configuration failed validation."
  write_frps
  "$BIN/frps" verify -c "$ETC/frps.toml" || die "FRPS config validation failed."
  write_systemd_iran
  write_meta
  make_pair
  write_health_cli

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null || true
    ufw allow "${CONTROL_PORT}/tcp" >/dev/null || true
    ufw allow "${PUBLIC_PORT}/tcp" >/dev/null || true
  fi

  systemctl daemon-reload
  systemctl enable --now nginx >/dev/null
  systemctl reload nginx
  systemctl enable --now "$SERVICE" >/dev/null
  sleep 2
  systemctl is-active --quiet "$SERVICE" || { journalctl -u "$SERVICE" -n 80 --no-pager; die "FRPS failed to start."; }

  green "IRAN SIDE READY."
  echo
  echo "PAIR CODE (secret; paste only into the Foreign installer):"
  cat "$ETC/pair-code.txt"
  echo
  echo "Health: frp-ali-health"
}

install_foreign(){
  ROLE=foreign
  if [[ -z ${PAIR_CODE:-} ]]; then prompt_secret PAIR_CODE "Paste Iran pair code"; fi
  decode_pair
  prompt LOCAL_PORT "Existing local Xray/3x-ui inbound port" "443"
  valid_port "$LOCAL_PORT" || die "Invalid local port."

  install_common_deps
  mkdir -p "$ETC" "$OPT" "$STATE"
  chmod 0700 "$ETC" "$STATE"
  backup_existing
  download_frp

  nc -z -w3 127.0.0.1 "$LOCAL_PORT" || die "Nothing is listening on 127.0.0.1:${LOCAL_PORT}. Xray/3x-ui was not touched."
  resolve_contains "$DOMAIN" "$IRAN_IP" || die "Tunnel domain does not currently resolve to the Iran IP in the pair code."
  curl -fsS --connect-timeout 5 --max-time 10 "https://${DOMAIN}:${CONTROL_PORT}/" -o /dev/null || {
    rc=$?; [[ $rc -eq 22 ]] || die "Cannot complete TLS/HTTP connection from Foreign to Iran ${DOMAIN}:${CONTROL_PORT}."
  }

  printf '%s\n' "$TOKEN" >"$ETC/token"
  chmod 0600 "$ETC/token"
  write_frpc_shards
  for f in "$ETC"/frpc-*.toml; do "$BIN/frpc" verify -c "$f" || die "FRPC validation failed: $f"; done
  write_systemd_foreign
  write_meta
  write_health_cli

  systemctl daemon-reload
  systemctl enable "$SERVICE" "${APP}-shard@02.service" "${APP}-shard@03.service" "${APP}-shard@04.service" >/dev/null
  systemctl restart "$SERVICE"
  sleep 2
  systemctl restart "${APP}-shard@02.service"; sleep 1
  systemctl restart "${APP}-shard@03.service"; sleep 1
  systemctl restart "${APP}-shard@04.service"
  sleep 5

  for u in "$SERVICE" "${APP}-shard@02.service" "${APP}-shard@03.service" "${APP}-shard@04.service"; do
    systemctl is-active --quiet "$u" || { journalctl -u "$u" -n 60 --no-pager; die "$u failed."; }
  done
  nc -z -w5 "$DOMAIN" "$PUBLIC_PORT" || yellow "Control tunnel is up, but public port ${PUBLIC_PORT} did not pass TCP gate yet. Check FRP registration/logs."

  green "FOREIGN SIDE READY."
  echo "Health: frp-ali-health"
}

uninstall_project(){
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  for n in 02 03 04; do systemctl disable --now "${APP}-shard@${n}.service" 2>/dev/null || true; done
  rm -f "/etc/systemd/system/${SERVICE}" "/etc/systemd/system/${APP}-shard@.service"
  rm -f "$NGINX_CONF" "/etc/nginx/conf.d/${APP}-acme.conf" "$NGINX_LIMIT_DROPIN" /usr/local/bin/frp-ali-health
  systemctl daemon-reload
  if command -v nginx >/dev/null 2>&1; then nginx -t >/dev/null 2>&1 && systemctl reload nginx || true; fi
  rm -rf "$ETC" "$OPT"
  green "Removed Ali Pro project components. Xray/3x-ui and Let's Encrypt certificates were preserved."
}

need_root
banner
case "${1:-}" in
  iran) install_iran ;;
  foreign) install_foreign ;;
  uninstall) uninstall_project ;;
  *) echo "Usage: $0 {iran|foreign|uninstall}"; exit 2 ;;
esac

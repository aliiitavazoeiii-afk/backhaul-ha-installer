#!/usr/bin/env bash
set -Eeuo pipefail

REPO='aliiitavazoeiii-afk/backhaul-ha-installer'
ENGINE_PIN='269494a90c1ab38be4338eb1314de47f6dbc6fe1'
EXPECTED_VERSION='0.2.0'
ROLE=''
IRAN_IP=''
DOMAIN=''
BUNDLE=''
STATE_DIR='/etc/aegis-single'
STATE_FILE="${STATE_DIR}/state.env"
AEGIS_BIN='/usr/local/bin/aegis'
AEGIS_SERVER_CFG="${STATE_DIR}/server.json"
AEGIS_CLIENT_CFG="${STATE_DIR}/client.json"
PRIMARY_BUNDLE='/root/aegis-primary.env'
BACKUP_ROOT='/root/aegis-single-backups'

log(){ printf '[+] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

usage(){
  cat <<'USAGE'
Aegis Single Primary installer

IRAN:
  install.sh --role iran --iran-ip IRAN_IP --domain DOMAIN

FOREIGN:
  install.sh --role foreign --bundle /root/aegis-primary.env
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --iran-ip) IRAN_IP="${2:-}"; shift 2;;
    --domain) DOMAIN="${2:-}"; shift 2;;
    --bundle) BUNDLE="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run as root.'
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || die '--role iran|foreign required.'
source /etc/os-release 2>/dev/null || die 'Cannot detect OS.'
case "${ID:-}" in ubuntu|debian) ;; *) die 'Ubuntu/Debian only.';; esac
case "$(uname -m)" in x86_64|amd64) ;; *) die 'amd64 only.';; esac

valid_ipv4(){
  local ip="$1" IFS=. a o
  read -r -a a <<< "$ip"
  [[ ${#a[@]} -eq 4 ]] || return 1
  for o in "${a[@]}"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] && ((10#$o <= 255)) || return 1
  done
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
version_ge(){ [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }
bget(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$2" | head -n1; }

backup_file(){
  local src="$1" dst="$2"
  [[ -e "$src" ]] || return 0
  cp -a "$src" "$dst"
}

make_backup_dir(){
  local d="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$d"
  printf '%s' "$d"
}

install_build_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl ca-certificates git tar python3 openssl iproute2 >/dev/null

  local have=''
  if command -v go >/dev/null 2>&1; then
    have="$(go version | awk '{print $3}' | sed 's/^go//')"
  fi
  if [[ -z "$have" ]] || ! version_ge "$have" '1.23.1'; then
    if apt-cache show golang-1.23-go >/dev/null 2>&1; then
      apt-get install -y golang-1.23-go >/dev/null
    else
      die 'Go >=1.23.1 is required and golang-1.23-go is unavailable.'
    fi
  fi
}

find_go(){
  local candidate ver
  for candidate in "$(command -v go 2>/dev/null || true)" /usr/lib/go-1.23/bin/go /usr/local/go/bin/go; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    ver="$($candidate version | awk '{print $3}' | sed 's/^go//')"
    if version_ge "$ver" '1.23.1'; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

build_aegis(){
  install_build_deps
  local work src go actual
  work="$(mktemp -d)"
  src="$work/src"
  mkdir -p "$src"
  git -C "$src" init -q
  git -C "$src" remote add origin "https://github.com/${REPO}.git"
  git -C "$src" fetch -q --depth 1 origin "$ENGINE_PIN" || { rm -rf "$work"; die 'Cannot fetch pinned Aegis source.'; }
  git -C "$src" checkout -q --detach FETCH_HEAD
  actual="$(git -C "$src" rev-parse HEAD)"
  [[ "$actual" == "$ENGINE_PIN" ]] || { rm -rf "$work"; die "Aegis source pin mismatch: $actual"; }

  go="$(find_go)" || { rm -rf "$work"; die 'No usable Go compiler found.'; }
  cd "$src/aegis-tunnel"
  [[ -z "$(gofmt -l .)" ]] || { cd /; rm -rf "$work"; die 'Pinned source unexpectedly fails gofmt.'; }
  "$go" vet ./...
  "$go" test ./... -count=1 -timeout=60s
  CGO_ENABLED=0 "$go" build -trimpath -ldflags='-s -w' -o "$work/aegis" ./cmd/aegis
  [[ "$($work/aegis -version)" == "$EXPECTED_VERSION" ]] || { cd /; rm -rf "$work"; die 'Aegis version verification failed.'; }
  install -m 0755 "$work/aegis" "$AEGIS_BIN"
  cd /
  rm -rf "$work"
  log "Aegis ${EXPECTED_VERSION} installed from pinned commit ${ENGINE_PIN}."
}

write_server_unit(){
  cat > /etc/systemd/system/aegis-server.service <<EOFUNIT
[Unit]
Description=Aegis Single Primary server
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${AEGIS_BIN} -role server -config ${AEGIS_SERVER_CFG}
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOFUNIT
}

write_client_unit(){
  cat > /etc/systemd/system/aegis-client.service <<EOFUNIT
[Unit]
Description=Aegis Single Primary Foreign client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${AEGIS_BIN} -role client -config ${AEGIS_CLIENT_CFG}
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOFUNIT
}

write_aegisctl_iran(){
  cat > /usr/local/bin/aegisctl <<'CTL'
#!/usr/bin/env bash
set -u
cmd="${1:-status}"
case "$cmd" in
  status)
    echo '=== Aegis Single Primary ==='
    printf 'aegis-server: '; systemctl is-active aegis-server 2>/dev/null || true
    printf 'nginx:        '; systemctl is-active nginx 2>/dev/null || true
    printf 'haproxy:      '; systemctl is-active haproxy 2>/dev/null || true
    if timeout 1 bash -c '</dev/tcp/127.0.0.1/10444' 2>/dev/null; then
      echo 'primary-ready: UP'
    else
      echo 'primary-ready: DOWN'
    fi
    echo
    grep -A8 '^backend user_gateway' /etc/haproxy/haproxy.cfg 2>/dev/null || true
    ;;
  logs)
    journalctl -u aegis-server -u nginx -u haproxy -n 160 --no-pager
    ;;
  restart)
    systemctl restart aegis-server nginx haproxy
    sleep 2
    exec "$0" status
    ;;
  *) echo 'Usage: aegisctl {status|logs|restart}'; exit 2;;
esac
CTL
  chmod 0755 /usr/local/bin/aegisctl
}

write_aegisctl_foreign(){
  cat > /usr/local/bin/aegisctl <<'CTL'
#!/usr/bin/env bash
set -u
cmd="${1:-status}"
case "$cmd" in
  status)
    echo '=== Aegis Foreign Primary ==='
    printf 'aegis-client: '; systemctl is-active aegis-client 2>/dev/null || true
    if timeout 1 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null; then
      echo 'xray-local:   UP'
    else
      echo 'xray-local:   DOWN'
    fi
    ;;
  logs) journalctl -u aegis-client -n 160 --no-pager;;
  restart) systemctl restart aegis-client; sleep 2; exec "$0" status;;
  *) echo 'Usage: aegisctl {status|logs|restart}'; exit 2;;
esac
CTL
  chmod 0755 /usr/local/bin/aegisctl
}

install_iran_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y nginx haproxy certbot >/dev/null
}

preflight_iran(){
  [[ -n "$IRAN_IP" ]] || die '--iran-ip required.'
  [[ -n "$DOMAIN" ]] || die '--domain required.'
  valid_ipv4 "$IRAN_IP" || die 'Invalid Iran IPv4.'
  valid_domain "$DOMAIN" || die 'Invalid domain.'

  local resolved
  resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
  [[ "$resolved" == "$IRAN_IP" ]] || die "$DOMAIN resolves to ${resolved:-nothing}; expected $IRAN_IP"

  if [[ ! -f "$STATE_FILE" ]] && ss -Hlnpt 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}'; then
    die 'Port 443 is already in use on Iran. Refusing to replace an unknown production listener.'
  fi
}

ensure_certificate(){
  if [[ -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" && -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
    log "Existing certificate found for ${DOMAIN}."
    return
  fi
  systemctl stop nginx haproxy >/dev/null 2>&1 || true
  if ss -Hlnpt 2>/dev/null | awk '$4 ~ /:80$/ {found=1} END{exit !found}'; then
    die 'Port 80 is occupied; cannot issue the carrier certificate with standalone ACME.'
  fi
  certbot certonly --standalone -d "$DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive
}

load_or_create_identity(){
  install -d -m 0700 "$STATE_DIR"
  TOKEN=''
  PATH_PREFIX=''
  if [[ -f "$STATE_FILE" ]]; then
    TOKEN="$(bget TOKEN "$STATE_FILE")"
    PATH_PREFIX="$(bget PATH_PREFIX "$STATE_FILE")"
  fi
  if [[ ! "$TOKEN" =~ ^[0-9a-f]{64}$ ]]; then
    TOKEN="$(openssl rand -hex 32)"
  fi
  if [[ ! "$PATH_PREFIX" =~ ^/[A-Za-z0-9/_-]{20,160}$ ]]; then
    PATH_PREFIX="/edge/v1/$(openssl rand -hex 20)"
  fi
  umask 077
  cat > "$STATE_FILE" <<EOFSTATE
ROLE='iran'
IRAN_IP='${IRAN_IP}'
DOMAIN='${DOMAIN}'
TOKEN='${TOKEN}'
PATH_PREFIX='${PATH_PREFIX}'
ENGINE_PIN='${ENGINE_PIN}'
EOFSTATE
  chmod 0600 "$STATE_FILE"
}

write_iran_configs(){
  local backup
  backup="$(make_backup_dir)"
  backup_file /etc/haproxy/haproxy.cfg "$backup/haproxy.cfg"
  backup_file /etc/nginx/conf.d/aegis-single.conf "$backup/aegis-single.conf"
  backup_file "$AEGIS_SERVER_CFG" "$backup/server.json"

  cat > "$AEGIS_SERVER_CFG" <<EOFJSON
{
  "bind": "127.0.0.1:18080",
  "token": "${TOKEN}",
  "path_prefix": "${PATH_PREFIX}",
  "keepalive_seconds": 8,
  "readiness_listen": "127.0.0.1:10444",
  "listeners": [
    {"listen":"127.0.0.1:10443","target_id":1}
  ]
}
EOFJSON
  chmod 0600 "$AEGIS_SERVER_CFG"

  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/conf.d/aegis-single.conf <<EOFNGINX
server {
    listen 127.0.0.1:9443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ ${PATH_PREFIX}/ {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header Origin \$http_origin;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_pass http://127.0.0.1:18080;
    }

    location / { return 404; }
}
EOFNGINX

  cat > /etc/haproxy/haproxy.cfg <<EOFHAPROXY
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 20000
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
    tcp-request inspect-delay 2s
    tcp-request content accept if { req_ssl_hello_type 1 }
    acl aegis_carrier req.ssl_sni -i ${DOMAIN}
    use_backend aegis_carrier_tls if aegis_carrier
    default_backend user_gateway

backend aegis_carrier_tls
    mode tcp
    server local_nginx 127.0.0.1:9443 check inter 2s fall 3 rise 2

backend user_gateway
    mode tcp
    option redispatch
    retries 2
    server aegis_primary 127.0.0.1:10443 check port 10444 inter 2s fall 3 rise 3 on-marked-down shutdown-sessions
EOFHAPROXY

  nginx -t
  haproxy -c -f /etc/haproxy/haproxy.cfg
  log "Configs validated. Backup: $backup"
}

write_bundle(){
  umask 077
  cat > "$PRIMARY_BUNDLE" <<EOFBUNDLE
ROLE='foreign-primary'
IRAN_IP='${IRAN_IP}'
DOMAIN='${DOMAIN}'
TOKEN='${TOKEN}'
PATH_PREFIX='${PATH_PREFIX}'
ENGINE_PIN='${ENGINE_PIN}'
EOFBUNDLE
  chmod 0600 "$PRIMARY_BUNDLE"
}

install_iran(){
  preflight_iran
  build_aegis
  install_iran_packages
  ensure_certificate
  load_or_create_identity
  write_server_unit
  write_iran_configs
  write_bundle
  write_aegisctl_iran

  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/aegis-nginx <<'EOFHOOK'
#!/usr/bin/env bash
systemctl reload nginx
EOFHOOK
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/aegis-nginx

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 443/tcp >/dev/null || true
    ufw allow 80/tcp >/dev/null || true
  fi

  systemctl daemon-reload
  systemctl enable --now aegis-server nginx haproxy >/dev/null
  sleep 2
  systemctl is-active --quiet aegis-server || die 'aegis-server failed to start.'
  systemctl is-active --quiet nginx || die 'nginx failed to start.'
  systemctl is-active --quiet haproxy || die 'haproxy failed to start.'

  log 'IRAN Aegis Single Primary installed.'
  echo "[+] Bundle: ${PRIMARY_BUNDLE}"
  echo '[i] Primary readiness will remain DOWN until the Foreign client connects and its Xray is healthy.'
  aegisctl status || true
}

preflight_foreign(){
  [[ -n "$BUNDLE" && -f "$BUNDLE" ]] || die '--bundle file required on Foreign.'
  [[ "$(bget ROLE "$BUNDLE")" == 'foreign-primary' ]] || die 'Invalid bundle role.'
  IRAN_IP="$(bget IRAN_IP "$BUNDLE")"
  DOMAIN="$(bget DOMAIN "$BUNDLE")"
  TOKEN="$(bget TOKEN "$BUNDLE")"
  PATH_PREFIX="$(bget PATH_PREFIX "$BUNDLE")"
  valid_ipv4 "$IRAN_IP" || die 'Invalid Iran IP in bundle.'
  valid_domain "$DOMAIN" || die 'Invalid domain in bundle.'
  [[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid token in bundle.'
  [[ "$PATH_PREFIX" =~ ^/[A-Za-z0-9/_-]{20,160}$ ]] || die 'Invalid path in bundle.'

  if ! timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null; then
    die 'Xray is not listening on 127.0.0.1:443. Nothing was changed.'
  fi
}

install_foreign(){
  preflight_foreign
  build_aegis
  install -d -m 0700 "$STATE_DIR"
  local backup
  backup="$(make_backup_dir)"
  backup_file "$AEGIS_CLIENT_CFG" "$backup/client.json"

  cat > "$AEGIS_CLIENT_CFG" <<EOFJSON
{
  "remote_addr": "${DOMAIN}:443",
  "edge_ip": "${IRAN_IP}",
  "scheme": "wss",
  "tls_server_name": "${DOMAIN}",
  "tls_skip_verify": false,
  "token": "${TOKEN}",
  "path_prefix": "${PATH_PREFIX}",
  "origin": "https://${DOMAIN}",
  "pool": 4,
  "dial_timeout_seconds": 8,
  "keepalive_seconds": 8,
  "health_target": "127.0.0.1:443",
  "health_interval_seconds": 2,
  "targets": [
    {"id":1,"address":"127.0.0.1:443"}
  ]
}
EOFJSON
  chmod 0600 "$AEGIS_CLIENT_CFG"

  umask 077
  cat > "$STATE_FILE" <<EOFSTATE
ROLE='foreign-primary'
IRAN_IP='${IRAN_IP}'
DOMAIN='${DOMAIN}'
ENGINE_PIN='${ENGINE_PIN}'
EOFSTATE
  chmod 0600 "$STATE_FILE"

  write_client_unit
  write_aegisctl_foreign
  systemctl daemon-reload
  systemctl enable --now aegis-client >/dev/null
  sleep 3
  systemctl is-active --quiet aegis-client || die 'aegis-client failed to start.'
  log "FOREIGN Aegis client installed; Xray was preserved. Backup: $backup"
  aegisctl status || true
}

case "$ROLE" in
  iran) install_iran;;
  foreign) install_foreign;;
esac

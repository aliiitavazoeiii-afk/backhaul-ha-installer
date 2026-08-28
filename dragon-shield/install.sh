#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_URL="https://github.com/aliiitavazoeiii-afk/backhaul-ha-installer.git"
BRANCH="agent/dragon-shield-v1"
RAW_BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${BRANCH}/dragon-shield"
SRC_DIR="/opt/dragon-shield-src"
BIN="/usr/local/bin/dragon-shield"
ETC_DIR="/etc/dragon-shield"
SERVICE="/etc/systemd/system/dragon-shield.service"
SYSCTL_FILE="/etc/sysctl.d/99-dragon-shield.conf"
DEFAULT_SERVER_CIDR="10.203.0.1/24"
DEFAULT_CLIENT_IP="10.203.0.2"
DEFAULT_MTU="1080"

log() { printf '[dragon-shield] %s\n' "$*"; }
die() { printf '[dragon-shield] ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"; }

usage() {
  cat <<USAGE
Dragon Shield installer

Server:
  bash <(curl -fsSL ${RAW_BASE}/install.sh) server \\
    --domain shield.example.com \\
    --client-id iran1 \\
    --client-ip 10.203.0.2

Client:
  bash <(curl -fsSL ${RAW_BASE}/install.sh) client --enroll '<TOKEN_PRINTED_BY_SERVER>'

Add another ingress to an existing server:
  bash <(curl -fsSL ${RAW_BASE}/install.sh) add-client --id iran2 --ip 10.203.0.3

Other commands:
  status
  uninstall
USAGE
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl git iproute2 openssl python3 certbot
}

version_ge_125() {
  command -v go >/dev/null 2>&1 || return 1
  local v major minor
  v="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
  major="${v%%.*}"
  minor="${v#*.}"; minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > 1 || (major == 1 && minor >= 25) ))
}

install_go() {
  if version_ge_125; then
    return
  fi
  local gov arch tarball
  gov="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
  [[ "$gov" == go* ]] || die "could not determine current Go version"
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
  tarball="/tmp/${gov}.linux-${arch}.tar.gz"
  log "installing ${gov}"
  curl -fL "https://go.dev/dl/${gov}.linux-${arch}.tar.gz" -o "$tarball"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tarball"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  export PATH="/usr/local/go/bin:$PATH"
}

build_binary() {
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
  cd "$SRC_DIR/dragon-shield"
  export PATH="/usr/local/go/bin:$PATH"
  GOTOOLCHAIN=local go build -trimpath -ldflags='-s -w' -o "$BIN" ./cmd/dragon-shield
  chmod 0755 "$BIN"
  log "installed $($BIN version)"
}

write_sysctl() {
  cat >"$SYSCTL_FILE" <<'SYSCTL'
# Dragon Shield QUIC socket headroom.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
SYSCTL
  sysctl --system >/dev/null 2>&1 || true
}

open_firewall_server() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 443/tcp >/dev/null || true
    ufw allow 443/udp >/dev/null || true
    ufw allow 80/tcp >/dev/null || true
  fi
}

write_service() {
  local role="$1" config="$2"
  cat >"$SERVICE" <<UNIT
[Unit]
Description=Dragon Shield ${role}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=${BIN} prepare-tun -config ${config}
ExecStart=${BIN} ${role} -config ${config}
Restart=always
RestartSec=1
TimeoutStopSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now dragon-shield.service
}

ensure_cert() {
  local domain="$1" cert_override="$2" key_override="$3"
  if [[ -n "$cert_override" || -n "$key_override" ]]; then
    [[ -n "$cert_override" && -n "$key_override" ]] || die "--cert and --key must be supplied together"
    [[ -r "$cert_override" && -r "$key_override" ]] || die "certificate or key is unreadable"
    printf '%s\t%s\n' "$cert_override" "$key_override"
    return
  fi
  local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local key="/etc/letsencrypt/live/${domain}/privkey.pem"
  if [[ ! -r "$cert" || ! -r "$key" ]]; then
    log "requesting a Let's Encrypt certificate for ${domain}; DNS must already point here and TCP/80 must be reachable"
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain"
  fi
  printf '%s\t%s\n' "$cert" "$key"
}

make_enrollment() {
  local cfg="$1" client_id="$2"
  python3 - "$cfg" "$client_id" <<'PY'
import base64, ipaddress, json, sys
cfg=json.load(open(sys.argv[1]))
cid=sys.argv[2]
client=next((x for x in cfg['clients'] if x['id']==cid), None)
if not client:
    raise SystemExit('client not found')
iface=ipaddress.ip_interface(cfg['tun_cidr'])
client_cidr=f"{client['ip']}/{iface.network.prefixlen}"
payload={
    'v':1,
    'server':f"{cfg['public_domain']}:443",
    'server_name':cfg['public_domain'],
    'server_tun_ip':str(iface.ip),
    'tun_cidr':client_cidr,
    'mtu':cfg.get('mtu',1080),
    'client_id':client['id'],
    'token':client['token'],
    'webtransport_path':cfg['webtransport_path'],
    'websocket_path':cfg['websocket_path'],
    'mode':'auto',
}
raw=json.dumps(payload,separators=(',',':')).encode()
print(base64.urlsafe_b64encode(raw).decode().rstrip('='))
PY
}

install_server() {
  local domain="" client_id="iran1" client_ip="$DEFAULT_CLIENT_IP" server_cidr="$DEFAULT_SERVER_CIDR" mtu="$DEFAULT_MTU" cert="" key=""
  while (($#)); do
    case "$1" in
      --domain) domain="${2:-}"; shift 2 ;;
      --client-id) client_id="${2:-}"; shift 2 ;;
      --client-ip) client_ip="${2:-}"; shift 2 ;;
      --server-cidr) server_cidr="${2:-}"; shift 2 ;;
      --mtu) mtu="${2:-}"; shift 2 ;;
      --cert) cert="${2:-}"; shift 2 ;;
      --key) key="${2:-}"; shift 2 ;;
      *) die "unknown server option: $1" ;;
    esac
  done
  [[ -n "$domain" ]] || die "--domain is required"
  python3 - "$server_cidr" "$client_ip" <<'PY'
import ipaddress, sys
net=ipaddress.ip_interface(sys.argv[1]).network
ip=ipaddress.ip_address(sys.argv[2])
if ip not in net:
    raise SystemExit('client IP is outside server subnet')
if ip == ipaddress.ip_interface(sys.argv[1]).ip:
    raise SystemExit('client IP cannot equal server IP')
PY

  install_packages
  install_go
  build_binary
  write_sysctl
  open_firewall_server
  mkdir -p "$ETC_DIR"

  local cert_key cert_path key_path token wt ws
  cert_key="$(ensure_cert "$domain" "$cert" "$key")"
  cert_path="${cert_key%%$'\t'*}"
  key_path="${cert_key#*$'\t'}"
  token="$(openssl rand -base64 36 | tr -d '\n')"
  wt="/assets/$(openssl rand -hex 12)"
  ws="/api/events/$(openssl rand -hex 12)"

  cat >"$ETC_DIR/server.json" <<JSON
{
  "role": "server",
  "listen": ":443",
  "public_domain": "${domain}",
  "tls_cert": "${cert_path}",
  "tls_key": "${key_path}",
  "tun_name": "dfrshield0",
  "tun_cidr": "${server_cidr}",
  "mtu": ${mtu},
  "webtransport_path": "${wt}",
  "websocket_path": "${ws}",
  "clients": [
    {"id": "${client_id}", "ip": "${client_ip}", "token": "${token}"}
  ]
}
JSON
  chmod 0600 "$ETC_DIR/server.json"
  write_service server "$ETC_DIR/server.json"

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy 2>/dev/null || true
  cat >/etc/letsencrypt/renewal-hooks/deploy/dragon-shield-restart.sh <<'HOOK'
#!/bin/sh
systemctl try-restart dragon-shield.service >/dev/null 2>&1 || true
HOOK
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/dragon-shield-restart.sh

  local enroll
  enroll="$(make_enrollment "$ETC_DIR/server.json" "$client_id")"
  printf '%s\n' "$enroll" >"/root/dragon-shield-enroll-${client_id}.txt"
  chmod 0600 "/root/dragon-shield-enroll-${client_id}.txt"

  log "server is running"
  echo
  echo "=== CLIENT ENROLLMENT ==="
  echo "$enroll"
  echo
  echo "Run on the Iran/Ingress server:"
  printf "bash <(curl -fsSL %q) client --enroll %q\n" "${RAW_BASE}/install.sh" "$enroll"
  echo
  echo "After the client connects, verify the overlay with:"
  echo "  ping -c 3 $(python3 -c 'import ipaddress,json; c=json.load(open("/etc/dragon-shield/server.json")); print(ipaddress.ip_interface(c["tun_cidr"]).ip)')"
}

install_client() {
  local enroll=""
  while (($#)); do
    case "$1" in
      --enroll) enroll="${2:-}"; shift 2 ;;
      *) die "unknown client option: $1" ;;
    esac
  done
  [[ -n "$enroll" ]] || die "--enroll is required"
  install_packages
  install_go
  build_binary
  write_sysctl
  mkdir -p "$ETC_DIR"
  ENROLL="$enroll" python3 - "$ETC_DIR/client.json" <<'PY'
import base64, json, os, sys
s=os.environ['ENROLL']
s += '=' * (-len(s) % 4)
e=json.loads(base64.urlsafe_b64decode(s.encode()))
if e.get('v') != 1:
    raise SystemExit('unsupported enrollment version')
required=['server','server_name','server_tun_ip','tun_cidr','client_id','token','webtransport_path','websocket_path']
for k in required:
    if not e.get(k): raise SystemExit(f'missing enrollment field: {k}')
cfg={
    'role':'client',
    'server':e['server'],
    'server_name':e['server_name'],
    'tun_name':'dfrshield0',
    'tun_cidr':e['tun_cidr'],
    'mtu':int(e.get('mtu',1080)),
    'server_tun_ip':e['server_tun_ip'],
    'client_id':e['client_id'],
    'token':e['token'],
    'webtransport_path':e['webtransport_path'],
    'websocket_path':e['websocket_path'],
    'mode':e.get('mode','auto'),
}
with open(sys.argv[1],'w') as f:
    json.dump(cfg,f,indent=2)
    f.write('\n')
PY
  chmod 0600 "$ETC_DIR/client.json"
  write_service client "$ETC_DIR/client.json"
  log "client is running"
  echo
  echo "Overlay server IP: $(python3 -c 'import json; print(json.load(open("/etc/dragon-shield/client.json"))["server_tun_ip"])')"
  echo "Test: ping -c 3 $(python3 -c 'import json; print(json.load(open("/etc/dragon-shield/client.json"))["server_tun_ip"])')"
  echo "Logs: journalctl -u dragon-shield -f"
}

add_client() {
  local cid="" ip=""
  while (($#)); do
    case "$1" in
      --id) cid="${2:-}"; shift 2 ;;
      --ip) ip="${2:-}"; shift 2 ;;
      *) die "unknown add-client option: $1" ;;
    esac
  done
  [[ -n "$cid" && -n "$ip" ]] || die "add-client requires --id and --ip"
  [[ -f "$ETC_DIR/server.json" ]] || die "server config not found"
  local token
  token="$(openssl rand -base64 36 | tr -d '\n')"
  CLIENT_ID="$cid" CLIENT_IP="$ip" CLIENT_TOKEN="$token" python3 - "$ETC_DIR/server.json" <<'PY'
import ipaddress, json, os, sys
path=sys.argv[1]
with open(path) as f: cfg=json.load(f)
cid=os.environ['CLIENT_ID']; ip=os.environ['CLIENT_IP']; token=os.environ['CLIENT_TOKEN']
iface=ipaddress.ip_interface(cfg['tun_cidr'])
addr=ipaddress.ip_address(ip)
if addr not in iface.network or addr == iface.ip:
    raise SystemExit('invalid client IP for server subnet')
if any(x['id']==cid or x['ip']==ip for x in cfg['clients']):
    raise SystemExit('duplicate client id or ip')
cfg['clients'].append({'id':cid,'ip':ip,'token':token})
with open(path,'w') as f:
    json.dump(cfg,f,indent=2); f.write('\n')
PY
  chmod 0600 "$ETC_DIR/server.json"
  systemctl restart dragon-shield.service
  local enroll
  enroll="$(make_enrollment "$ETC_DIR/server.json" "$cid")"
  printf '%s\n' "$enroll" >"/root/dragon-shield-enroll-${cid}.txt"
  chmod 0600 "/root/dragon-shield-enroll-${cid}.txt"
  echo "=== CLIENT ENROLLMENT ==="
  echo "$enroll"
  echo
  printf "bash <(curl -fsSL %q) client --enroll %q\n" "${RAW_BASE}/install.sh" "$enroll"
}

status_cmd() {
  systemctl --no-pager --full status dragon-shield.service || true
  echo
  ip -details addr show dfrshield0 2>/dev/null || true
  echo
  journalctl -u dragon-shield.service -n 30 --no-pager 2>/dev/null || true
}

uninstall_cmd() {
  systemctl disable --now dragon-shield.service 2>/dev/null || true
  rm -f "$SERVICE"
  systemctl daemon-reload
  ip link del dfrshield0 2>/dev/null || true
  rm -f "$BIN" "$SYSCTL_FILE"
  rm -rf "$ETC_DIR" "$SRC_DIR"
  sysctl --system >/dev/null 2>&1 || true
  log "removed Dragon Shield; TLS certificates were left untouched"
}

main() {
  need_root
  case "${1:-}" in
    server) shift; install_server "$@" ;;
    client) shift; install_client "$@" ;;
    add-client) shift; add_client "$@" ;;
    status) status_cmd ;;
    uninstall) uninstall_cmd ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command: $1" ;;
  esac
}

main "$@"

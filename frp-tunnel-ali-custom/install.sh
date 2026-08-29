#!/usr/bin/env bash
set -Eeuo pipefail

APP="frp-tunnel-ali"
BRAND="FRP Tunnel — Ali Tavazoei Custom Version"
ETC="/etc/${APP}"
STATE="/var/lib/${APP}"
BIN="/usr/local/bin"
FRP_VERSION="0.71.0"
FRP_AMD64_SHA256="84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716"
FRP_ARM64_SHA256="f33c293c275d8fc68c654b6fba8f10b2551d6463d09a9fc9cffb7227eae82266"

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'

die(){ echo "${C_RED}ERROR:${C_RESET} $*" >&2; exit 1; }
info(){ echo "${C_CYAN}::${C_RESET} $*"; }
ok(){ echo "${C_GREEN}OK${C_RESET}  $*"; }
warn(){ echo "${C_YELLOW}!!${C_RESET}  $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."

banner() {
  clear 2>/dev/null || true
  cat <<EOT
${C_BOLD}${C_CYAN}
╔══════════════════════════════════════════════════════════════╗
║  FRP TUNNEL — ALI TAVAZOEI CUSTOM VERSION                  ║
║  Stable / WSS-TLS / No shared TCP multiplexing             ║
╚══════════════════════════════════════════════════════════════╝
${C_RESET}
EOT
}

prompt() {
  local __var="$1" __text="$2" __default="${3:-}" __value
  if [[ -n "$__default" ]]; then
    read -r -p "$__text [$__default]: " __value
    __value="${__value:-$__default}"
  else
    read -r -p "$__text: " __value
  fi
  printf -v "$__var" '%s' "$__value"
}

prompt_secret() {
  local __var="$1" __text="$2" __value
  read -r -s -p "$__text: " __value
  echo
  printf -v "$__var" '%s' "$__value"
}

valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
valid_ip_or_host(){ [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]; }

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y ca-certificates curl tar openssl jq iproute2 netcat-openbsd >/dev/null
}

backup_existing() {
  mkdir -p "$STATE/backups"
  if [[ -d "$ETC" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    tar -C / -czf "$STATE/backups/etc-${ts}.tar.gz" "${ETC#/}" 2>/dev/null || true
    ok "Backup saved: $STATE/backups/etc-${ts}.tar.gz"
  fi
}

download_frp() {
  local arch pkg sha url tmp dir
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) pkg="frp_${FRP_VERSION}_linux_amd64.tar.gz"; sha="$FRP_AMD64_SHA256" ;;
    aarch64|arm64) pkg="frp_${FRP_VERSION}_linux_arm64.tar.gz"; sha="$FRP_ARM64_SHA256" ;;
    *) die "Unsupported architecture: $arch (supported: amd64, arm64)" ;;
  esac
  tmp="$(mktemp -d)"
  url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${pkg}"
  info "Downloading FRP v${FRP_VERSION}..."
  curl -fL --retry 4 --connect-timeout 15 "$url" -o "$tmp/$pkg"
  echo "$sha  $tmp/$pkg" | sha256sum -c - >/dev/null || die "FRP checksum verification failed."
  tar -xzf "$tmp/$pkg" -C "$tmp"
  dir="$tmp/${pkg%.tar.gz}"
  install -m 0755 "$dir/frps" "$BIN/frps"
  install -m 0755 "$dir/frpc" "$BIN/frpc"
  rm -rf "$tmp"
  ok "Pinned FRP core v${FRP_VERSION} installed and checksum verified."
}

port_owner() { ss -H -ltnp "sport = :$1" 2>/dev/null | head -n1 || true; }

check_public_port_free_on_iran() {
  local p="$1" owner ans
  owner="$(port_owner "$p")"
  if [[ -n "$owner" ]]; then
    warn "TCP port $p is already listening:"
    echo "$owner"
    read -r -p "Continue anyway? This installer will NOT stop it. [y/N]: " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || die "Choose a free port and run again."
  fi
}

write_systemd() {
  local role="$1" exe cfg
  if [[ "$role" == "iran" ]]; then exe="$BIN/frps"; cfg="$ETC/frps.toml"; else exe="$BIN/frpc"; cfg="$ETC/frpc.toml"; fi
  cat >"/etc/systemd/system/${APP}.service" <<EOT
[Unit]
Description=${BRAND}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exe} -c ${cfg}
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOT
  systemctl daemon-reload
  systemctl enable "${APP}.service" >/dev/null
}

install_panel() {
  local src_url="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/frp-tunnel-ali-custom-v1/frp-tunnel-ali-custom/frp-tunnel"
  info "Installing management panel..."
  curl -fL --retry 4 "$src_url" -o "$BIN/frp-tunnel"
  chmod 0755 "$BIN/frp-tunnel"
}

write_meta() {
  mkdir -p "$ETC" "$STATE"
  chmod 700 "$ETC"
  cat >"$ETC/meta.env" <<EOT
ROLE='$ROLE'
IRAN_IP='$IRAN_IP'
FOREIGN_IP='$FOREIGN_IP'
DOMAIN='$DOMAIN'
CONTROL_PORT='$CONTROL_PORT'
PUBLIC_PORT='$PUBLIC_PORT'
LOCAL_TARGET_IP='${LOCAL_TARGET_IP:-}'
LOCAL_TARGET_PORT='${LOCAL_TARGET_PORT_PORT:-${LOCAL_TARGET_PORT:-}}'
FRP_VERSION='$FRP_VERSION'
PROFILE='stable-wss-no-tcpmux'
EOT
  chmod 600 "$ETC/meta.env"
}

make_pair_code() {
  local payload
  payload="$(jq -cn --arg iran "$IRAN_IP" --arg foreign "$FOREIGN_IP" --arg domain "$DOMAIN" --arg cp "$CONTROL_PORT" --arg pp "$PUBLIC_PORT" --arg token "$TOKEN" '{v:"1",iran:$iran,foreign:$foreign,domain:$domain,control_port:$cp,public_port:$pp,token:$token}')"
  PAIR_CODE="$(printf '%s' "$payload" | base64 -w0)"
  printf '%s\n' "$PAIR_CODE" >"$ETC/pair-code.txt"
  chmod 600 "$ETC/pair-code.txt"
}

install_iran() {
  ROLE="iran"
  prompt IRAN_IP "Iran server public IPv4"
  prompt FOREIGN_IP "Foreign server public IPv4 (label/health)"
  prompt DOMAIN "Tunnel domain (must resolve to Iran server)"
  prompt CONTROL_PORT "FRP WSS/TLS control port" "8443"
  prompt PUBLIC_PORT "Public user port on Iran" "443"
  valid_ip_or_host "$IRAN_IP" || die "Invalid Iran IP."
  valid_ip_or_host "$FOREIGN_IP" || die "Invalid Foreign IP."
  valid_ip_or_host "$DOMAIN" || die "Invalid domain."
  valid_port "$CONTROL_PORT" || die "Invalid control port."
  valid_port "$PUBLIC_PORT" || die "Invalid public port."
  [[ "$CONTROL_PORT" != "$PUBLIC_PORT" ]] || die "Control port and public user port must differ on one IP."
  check_public_port_free_on_iran "$CONTROL_PORT"
  check_public_port_free_on_iran "$PUBLIC_PORT"

  TOKEN="$(openssl rand -hex 32)"
  DASH_USER="ali"
  DASH_PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
  mkdir -p "$ETC"
  cat >"$ETC/frps.toml" <<EOT
bindAddr = "0.0.0.0"
bindPort = ${CONTROL_PORT}

auth.method = "token"
auth.token = "${TOKEN}"

# Stability profile: disable shared TCP multiplexing so unrelated user streams
# do not share one loss-sensitive carrier connection.
transport.tcpMux = false
transport.tcpKeepalive = 30
transport.maxPoolCount = 64
transport.tls.force = true

# Local-only dashboard.
webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "${DASH_USER}"
webServer.password = "${DASH_PASS}"

log.to = "console"
log.level = "info"
log.maxDays = 3
EOT
  "$BIN/frps" verify -c "$ETC/frps.toml" || die "frps config validation failed."
  write_systemd "$ROLE"
  write_meta
  make_pair_code
  systemctl restart "${APP}.service"
  sleep 3
  cat >"$ETC/dashboard.txt" <<EOT
Dashboard (local only): http://127.0.0.1:7500
Username: ${DASH_USER}
Password: ${DASH_PASS}
SSH example: ssh -L 7500:127.0.0.1:7500 root@${IRAN_IP}
EOT
  chmod 600 "$ETC/dashboard.txt"
  echo
  ok "Iran side installed."
  echo "${C_BOLD}PAIR CODE — paste once on the Foreign installer:${C_RESET}"
  echo "$PAIR_CODE"
  echo "${C_DIM}Saved at $ETC/pair-code.txt${C_RESET}"
}

decode_pair_code() {
  local code="$1" json
  json="$(printf '%s' "$code" | base64 -d 2>/dev/null)" || return 1
  IRAN_IP="$(jq -r '.iran // empty' <<<"$json")"
  FOREIGN_IP="$(jq -r '.foreign // empty' <<<"$json")"
  DOMAIN="$(jq -r '.domain // empty' <<<"$json")"
  CONTROL_PORT="$(jq -r '.control_port // empty' <<<"$json")"
  PUBLIC_PORT="$(jq -r '.public_port // empty' <<<"$json")"
  TOKEN="$(jq -r '.token // empty' <<<"$json")"
  [[ -n "$IRAN_IP" && -n "$DOMAIN" && -n "$CONTROL_PORT" && -n "$PUBLIC_PORT" && -n "$TOKEN" ]]
}

install_foreign() {
  ROLE="foreign"
  echo "Paste the PAIR CODE from Iran, or leave blank for manual entry."
  read -r -p "PAIR CODE: " PAIR_CODE
  if [[ -n "$PAIR_CODE" ]]; then
    decode_pair_code "$PAIR_CODE" || die "Invalid pair code."
    ok "Pair code loaded: Iran=$IRAN_IP Domain=$DOMAIN Control=$CONTROL_PORT Public=$PUBLIC_PORT"
  else
    prompt IRAN_IP "Iran server public IPv4"
    prompt FOREIGN_IP "This Foreign server public IPv4"
    prompt DOMAIN "Tunnel domain (resolves to Iran)"
    prompt CONTROL_PORT "FRP WSS/TLS control port" "8443"
    prompt PUBLIC_PORT "Public user port on Iran" "443"
    prompt_secret TOKEN "Shared FRP token from Iran"
  fi
  prompt LOCAL_TARGET_IP "Foreign Xray/local inbound listen IP" "127.0.0.1"
  prompt LOCAL_TARGET_PORT "Foreign Xray/local inbound port" "443"
  prompt POOL_COUNT "Pre-established independent work connections" "24"

  valid_ip_or_host "$IRAN_IP" || die "Invalid Iran IP."
  valid_ip_or_host "$FOREIGN_IP" || die "Invalid Foreign IP."
  valid_ip_or_host "$DOMAIN" || die "Invalid domain."
  valid_port "$CONTROL_PORT" || die "Invalid control port."
  valid_port "$PUBLIC_PORT" || die "Invalid public port."
  valid_port "$LOCAL_TARGET_PORT" || die "Invalid local target port."
  [[ "$POOL_COUNT" =~ ^[0-9]+$ ]] && (( POOL_COUNT >= 0 && POOL_COUNT <= 64 )) || die "Pool count must be 0..64."

  if ! timeout 2 bash -c "</dev/tcp/${LOCAL_TARGET_IP}/${LOCAL_TARGET_PORT}" 2>/dev/null; then
    warn "Local target ${LOCAL_TARGET_IP}:${LOCAL_TARGET_PORT} is not accepting TCP now."
    read -r -p "Continue anyway? [y/N]: " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || die "Fix/start the local inbound first."
  else
    ok "Local target ${LOCAL_TARGET_IP}:${LOCAL_TARGET_PORT} reachable."
  fi

  mkdir -p "$ETC"
  cat >"$ETC/frpc.toml" <<EOT
serverAddr = "${DOMAIN}"
serverPort = ${CONTROL_PORT}
loginFailExit = false

auth.method = "token"
auth.token = "${TOKEN}"

# Encrypted WebSocket transport with domain SNI.
transport.protocol = "wss"
transport.tls.enable = true
transport.tls.serverName = "${DOMAIN}"
transport.tls.disableCustomTLSFirstByte = true

# Critical stability choice: disable shared TCP multiplexing.
transport.tcpMux = false
transport.poolCount = ${POOL_COUNT}
transport.dialServerTimeout = 10
transport.dialServerKeepalive = 30
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 60
transport.wireProtocol = "v1"

webServer.addr = "127.0.0.1"
webServer.port = 7400

log.to = "console"
log.level = "info"
log.maxDays = 3

[[proxies]]
name = "ali-vpn-tcp"
type = "tcp"
localIP = "${LOCAL_TARGET_IP}"
localPort = ${LOCAL_TARGET_PORT}
remotePort = ${PUBLIC_PORT}
transport.useEncryption = false
transport.useCompression = false
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 3
healthCheck.maxFailed = 3
healthCheck.intervalSeconds = 10
EOT
  "$BIN/frpc" verify -c "$ETC/frpc.toml" || die "frpc config validation failed."
  write_systemd "$ROLE"
  write_meta
  systemctl restart "${APP}.service"
  sleep 5
  ok "Foreign side installed."
}

post_health() {
  echo
  info "Running final health check..."
  "$BIN/frp-tunnel" health || true
  echo
  info "Management panel: ${C_BOLD}frp-tunnel${C_RESET}"
}

main() {
  banner
  install_deps
  backup_existing
  download_frp
  install_panel
  echo "Choose this server's role:"
  echo "  1) IRAN    — frps; users connect here"
  echo "  2) FOREIGN — frpc; forwards to local Xray"
  read -r -p "Role [1/2]: " role
  case "$role" in
    1|iran|IRAN) install_iran ;;
    2|foreign|FOREIGN) install_foreign ;;
    *) die "Invalid role." ;;
  esac
  post_health
}

main "$@"

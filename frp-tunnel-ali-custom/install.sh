#!/usr/bin/env bash
set -Eeuo pipefail

APP="frp-tunnel-ali"
BRAND="FRP Tunnel — Ali Tavazoei Custom Version"
APP_VERSION="0.2.0-rc1"
ETC="/etc/${APP}"
STATE="/var/lib/${APP}"
OPT="/opt/${APP}"
BIN="${OPT}/bin"
SERVICE="${APP}.service"
PANEL="/usr/local/bin/frp-tunnel"

FRP_VERSION="0.71.0"
FRP_AMD64_SHA256="84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716"
FRP_ARM64_SHA256="f33c293c275d8fc68c654b6fba8f10b2551d6463d09a9fc9cffb7227eae82266"

SOURCE_REF="${FRP_ALI_SOURCE_COMMIT:-agent/frp-tunnel-ali-custom-v2}"
SOURCE_BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${SOURCE_REF}/frp-tunnel-ali-custom"

R=$'\033[0m'; B=$'\033[1m'; C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; RED=$'\033[31m'; D=$'\033[2m'

die(){ echo "${RED}ERROR:${R} $*" >&2; exit 1; }
info(){ echo "${C}::${R} $*"; }
ok(){ echo "${G}OK${R}  $*"; }
warn(){ echo "${Y}!!${R}  $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."

banner() {
  clear 2>/dev/null || true
  cat <<EOT
${B}${C}
╔════════════════════════════════════════════════════════════════╗
║  FRP TUNNEL — ALI TAVAZOEI CUSTOM VERSION                    ║
║  v${APP_VERSION} · WSS/TLS · Dedicated TCP work connections   ║
╚════════════════════════════════════════════════════════════════╝
${R}
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

valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_ipv4() {
  local IFS=. a b c d extra
  read -r a b c d extra <<<"$1"
  [[ -z "${extra:-}" && "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  ((10#$a<=255 && 10#$b<=255 && 10#$c<=255 && 10#$d<=255))
}
valid_domain() {
  [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
valid_local_host() {
  [[ "$1" == "localhost" || "$1" == "::1" || "$1" =~ ^127\.([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || return 1
  if [[ "$1" =~ ^127\. ]]; then valid_ipv4 "$1"; else return 0; fi
}
valid_profile() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]; }

check_os() {
  [[ -r /etc/os-release ]] || die "Unsupported OS: /etc/os-release missing."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "This installer currently supports Ubuntu/Debian only (detected: ${ID:-unknown})." ;;
  esac
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y ca-certificates curl tar openssl jq iproute2 netcat-openbsd >/dev/null
}

backup_existing() {
  mkdir -p "$STATE/backups"
  chmod 0700 "$STATE" "$STATE/backups"
  if [[ -d "$ETC" ]]; then
    local ts out
    ts="$(date +%Y%m%d-%H%M%S)"
    out="$STATE/backups/etc-${ts}.tar.gz"
    tar -C / -czf "$out" "${ETC#/}"
    chmod 0600 "$out"
    ok "Backup saved: $out"
  fi
}

download_frp() {
  local arch pkg sha url tmp dir
  mkdir -p "$BIN"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) pkg="frp_${FRP_VERSION}_linux_amd64.tar.gz"; sha="$FRP_AMD64_SHA256" ;;
    aarch64|arm64) pkg="frp_${FRP_VERSION}_linux_arm64.tar.gz"; sha="$FRP_ARM64_SHA256" ;;
    *) die "Unsupported architecture: $arch (supported: amd64, arm64)." ;;
  esac
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${pkg}"
  info "Downloading pinned FRP v${FRP_VERSION}..."
  curl -fL --retry 4 --connect-timeout 15 "$url" -o "$tmp/$pkg"
  echo "$sha  $tmp/$pkg" | sha256sum -c - >/dev/null || die "FRP checksum verification failed."
  tar -xzf "$tmp/$pkg" -C "$tmp"
  dir="$tmp/${pkg%.tar.gz}"
  install -m 0755 "$dir/frps" "$BIN/frps"
  install -m 0755 "$dir/frpc" "$BIN/frpc"
  rm -rf "$tmp"
  trap - RETURN
  ok "FRP core installed privately under $BIN."
}

install_panel() {
  local tmp="$STATE/frp-tunnel.new"
  mkdir -p "$STATE"
  info "Installing management CLI from source ref ${SOURCE_REF}..."
  curl -fL --retry 4 "${SOURCE_BASE}/frp-tunnel" -o "$tmp"
  bash -n "$tmp" || die "Downloaded management CLI failed syntax validation."
  install -m 0755 "$tmp" "$PANEL"
  rm -f "$tmp"
}

service_pid() {
  systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || true
}

port_owner() {
  ss -H -ltnp "sport = :$1" 2>/dev/null | head -n1 || true
}

port_owned_by_our_service() {
  local p="$1" pid owner
  pid="$(service_pid)"
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
  owner="$(port_owner "$p")"
  [[ "$owner" == *"pid=$pid,"* ]]
}

require_port_available_or_ours() {
  local p="$1" owner
  owner="$(port_owner "$p")"
  [[ -z "$owner" ]] && return 0
  if port_owned_by_our_service "$p"; then
    warn "Port $p is currently owned by the existing ${SERVICE}; validated reconfiguration is allowed."
    return 0
  fi
  echo "$owner"
  die "TCP port $p is owned by another process. No listener will be stopped automatically."
}

check_domain_points_to_iran() {
  local found=1 ip
  while read -r ip; do
    [[ "$ip" == "$IRAN_IP" ]] && found=0
  done < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
  ((found==0)) || die "Domain $DOMAIN does not currently resolve to Iran IP $IRAN_IP. Fix DNS first."
}

cert_pubkey_hash() {
  openssl x509 -in "$1" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

key_pubkey_hash() {
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

validate_cert_pair() {
  local cert="$1" key="$2" cert_hash key_hash
  [[ -r "$cert" ]] || die "TLS certificate not readable: $cert"
  [[ -r "$key" ]] || die "TLS private key not readable: $key"
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "Invalid X.509 certificate: $cert"
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || die "Invalid TLS private key: $key"
  openssl x509 -in "$cert" -checkhost "$DOMAIN" -noout >/dev/null 2>&1 || die "Certificate does not match domain $DOMAIN."
  cert_hash="$(cert_pubkey_hash "$cert")"
  key_hash="$(key_pubkey_hash "$key")"
  [[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]] || die "Certificate and private key do not match."
  openssl x509 -in "$cert" -checkend 604800 -noout >/dev/null 2>&1 || die "Certificate expires in less than 7 days."
}

select_tls_certificate() {
  local default_cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  local default_key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  echo
  info "A publicly trusted certificate is required for the production WSS profile."
  if [[ -r "$default_cert" && -r "$default_key" ]]; then
    TLS_CERT="$default_cert"
    TLS_KEY="$default_key"
    ok "Detected Let's Encrypt certificate for $DOMAIN."
  else
    prompt TLS_CERT "Full-chain certificate path for $DOMAIN" "$default_cert"
    prompt TLS_KEY "Private key path for $DOMAIN" "$default_key"
  fi
  validate_cert_pair "$TLS_CERT" "$TLS_KEY"
}

meta_write_kv() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value"
}

write_meta() {
  mkdir -p "$ETC" "$STATE"
  chmod 0700 "$ETC" "$STATE"
  {
    meta_write_kv ROLE "$ROLE"
    meta_write_kv APP_VERSION "$APP_VERSION"
    meta_write_kv IRAN_IP "$IRAN_IP"
    meta_write_kv FOREIGN_IP "${FOREIGN_IP:-}"
    meta_write_kv DOMAIN "$DOMAIN"
    meta_write_kv CONTROL_PORT "$CONTROL_PORT"
    meta_write_kv PUBLIC_PORT "$PUBLIC_PORT"
    meta_write_kv LOCAL_TARGET_IP "${LOCAL_TARGET_IP:-}"
    meta_write_kv LOCAL_TARGET_PORT "${LOCAL_TARGET_PORT:-}"
    meta_write_kv POOL_COUNT "${POOL_COUNT:-}"
    meta_write_kv PROFILE "$PROFILE"
    meta_write_kv TLS_CERT "${TLS_CERT:-}"
    meta_write_kv TLS_KEY "${TLS_KEY:-}"
    meta_write_kv FRP_VERSION "$FRP_VERSION"
    meta_write_kv SOURCE_REF "$SOURCE_REF"
  } >"$ETC/meta.env"
  chmod 0600 "$ETC/meta.env"
}

write_systemd() {
  local exe cfg
  if [[ "$ROLE" == "iran" ]]; then
    exe="$BIN/frps"; cfg="$ETC/frps.toml"
  else
    exe="$BIN/frpc"; cfg="$ETC/frpc.toml"
  fi
  cat >"/etc/systemd/system/${SERVICE}" <<EOT
[Unit]
Description=${BRAND}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=${exe} verify -c ${cfg}
ExecStart=${exe} -c ${cfg}
Restart=always
RestartSec=2
TimeoutStopSec=20
KillSignal=SIGTERM
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
EOT
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
}

write_token() {
  mkdir -p "$ETC"
  printf '%s\n' "$TOKEN" >"$ETC/token"
  chmod 0600 "$ETC/token"
}

make_pair_code() {
  local payload
  payload="$(jq -cn \
    --arg iran "$IRAN_IP" \
    --arg foreign "$FOREIGN_IP" \
    --arg domain "$DOMAIN" \
    --arg cp "$CONTROL_PORT" \
    --arg pp "$PUBLIC_PORT" \
    --arg token "$TOKEN" \
    --arg profile "$PROFILE" \
    '{v:2,iran:$iran,foreign:$foreign,domain:$domain,control_port:$cp,public_port:$pp,token:$token,profile:$profile}')"
  PAIR_CODE="$(printf '%s' "$payload" | base64 -w0)"
  printf '%s\n' "$PAIR_CODE" >"$ETC/pair-code.txt"
  chmod 0600 "$ETC/pair-code.txt"
}

decode_pair_code() {
  local code="$1" json v
  json="$(printf '%s' "$code" | base64 -d 2>/dev/null)" || return 1
  v="$(jq -r '.v // empty' <<<"$json")"
  [[ "$v" == "2" ]] || return 1
  IRAN_IP="$(jq -r '.iran // empty' <<<"$json")"
  FOREIGN_IP="$(jq -r '.foreign // empty' <<<"$json")"
  DOMAIN="$(jq -r '.domain // empty' <<<"$json")"
  CONTROL_PORT="$(jq -r '.control_port // empty' <<<"$json")"
  PUBLIC_PORT="$(jq -r '.public_port // empty' <<<"$json")"
  TOKEN="$(jq -r '.token // empty' <<<"$json")"
  PROFILE="$(jq -r '.profile // "normal"' <<<"$json")"
  valid_ipv4 "$IRAN_IP" &&
    valid_ipv4 "$FOREIGN_IP" &&
    valid_domain "$DOMAIN" &&
    valid_port "$CONTROL_PORT" &&
    valid_port "$PUBLIC_PORT" &&
    valid_profile "$PROFILE" &&
    [[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]]
}

maybe_confirm_reconfigure() {
  if systemctl is-active --quiet "$SERVICE" && [[ "${RECONFIG_APPROVED:-0}" != "1" ]]; then
    echo
    warn "An active ${BRAND} service already exists."
    warn "The new config will be validated before the running service is restarted."
    read -r -p "Type APPLY to continue with a controlled reconfiguration: " ans
    [[ "$ans" == "APPLY" ]] || die "No changes applied to the running service."
    RECONFIG_APPROVED=1
  fi
}

write_frps_config() {
  DASH_USER="ali"
  DASH_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
  cat >"$ETC/frps.toml" <<EOT
bindAddr = "0.0.0.0"
bindPort = ${CONTROL_PORT}
proxyBindAddr = "0.0.0.0"

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "${ETC}/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

# Stability: no yamux/shared-TCP multiplexing. Each FRP work connection is
# an independent TCP/TLS/WSS connection and therefore has its own congestion state.
transport.tcpMux = false
transport.tcpKeepalive = 30
transport.maxPoolCount = 64
transport.heartbeatTimeout = 90

# Production TLS identity. No FRP-generated self-signed certificate.
transport.tls.force = true
transport.tls.certFile = "${TLS_CERT}"
transport.tls.keyFile = "${TLS_KEY}"

allowPorts = [{ single = ${PUBLIC_PORT} }]
maxPortsPerClient = 1
userConnTimeout = 10
detailedErrorsToClient = false

webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "${DASH_USER}"
webServer.password = "${DASH_PASS}"
webServer.pprofEnable = false

log.to = "console"
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true
EOT
  chmod 0600 "$ETC/frps.toml"
  "$BIN/frps" verify -c "$ETC/frps.toml" || die "frps config validation failed."
  cat >"$ETC/dashboard.txt" <<EOT
Dashboard (local only): http://127.0.0.1:7500
Username: ${DASH_USER}
Password: ${DASH_PASS}
SSH example: ssh -L 7500:127.0.0.1:7500 root@${IRAN_IP}
EOT
  chmod 0600 "$ETC/dashboard.txt"
}

write_frpc_config() {
  DASH_USER="ali"
  DASH_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
  cat >"$ETC/frpc.toml" <<EOT
clientID = "ali-${PROFILE}"
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

# Stability: each control/work connection is a real independent TCP connection.
transport.tcpMux = false
transport.poolCount = ${POOL_COUNT}
transport.dialServerTimeout = 10
transport.dialServerKeepalive = 30
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 90
transport.wireProtocol = "v1"

webServer.addr = "127.0.0.1"
webServer.port = 7400
webServer.user = "${DASH_USER}"
webServer.password = "${DASH_PASS}"
webServer.pprofEnable = false

log.to = "console"
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true

[[proxies]]
name = "ali-vpn-${PROFILE}"
type = "tcp"
localIP = "${LOCAL_TARGET_IP}"
localPort = ${LOCAL_TARGET_PORT}
remotePort = ${PUBLIC_PORT}
transport.useEncryption = false
transport.useCompression = false

# Local-target health is deliberately hysteretic. A short target hiccup marks the
# proxy degraded only after repeated failures; it does not kill the FRP control session.
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 3
healthCheck.maxFailed = 5
healthCheck.intervalSeconds = 5
EOT
  chmod 0600 "$ETC/frpc.toml"
  "$BIN/frpc" verify -c "$ETC/frpc.toml" || die "frpc config validation failed."
  cat >"$ETC/dashboard.txt" <<EOT
Dashboard (local only): http://127.0.0.1:7400
Username: ${DASH_USER}
Password: ${DASH_PASS}
SSH example: ssh -L 7400:127.0.0.1:7400 root@${FOREIGN_IP}
EOT
  chmod 0600 "$ETC/dashboard.txt"
}

install_iran() {
  ROLE="iran"
  prompt IRAN_IP "Iran server public IPv4"
  prompt FOREIGN_IP "Foreign server public IPv4"
  prompt DOMAIN "Tunnel domain (DNS-only/direct to Iran)"
  prompt PROFILE "Profile name" "normal"
  prompt CONTROL_PORT "FRP WSS/TLS control port" "8443"
  prompt PUBLIC_PORT "Public user port on Iran" "443"

  valid_ipv4 "$IRAN_IP" || die "Invalid Iran IPv4."
  valid_ipv4 "$FOREIGN_IP" || die "Invalid Foreign IPv4."
  valid_domain "$DOMAIN" || die "Invalid domain."
  valid_profile "$PROFILE" || die "Profile must be 1-32 chars: letters, numbers, dot, underscore or dash."
  valid_port "$CONTROL_PORT" || die "Invalid control port."
  valid_port "$PUBLIC_PORT" || die "Invalid public user port."
  [[ "$CONTROL_PORT" != "$PUBLIC_PORT" ]] || die "Direct WSS mode requires control and public user ports to differ."

  maybe_confirm_reconfigure
  check_domain_points_to_iran
  select_tls_certificate
  require_port_available_or_ours "$CONTROL_PORT"
  require_port_available_or_ours "$PUBLIC_PORT"

  TOKEN="$(openssl rand -hex 32)"
  write_token
  write_frps_config
  write_meta
  make_pair_code
  write_systemd

  systemctl restart "$SERVICE"
  sleep 2
  systemctl is-active --quiet "$SERVICE" || {
    journalctl -u "$SERVICE" -n 80 --no-pager
    die "frps failed to start."
  }

  echo
  ok "Iran node is installed and the control endpoint is up."
  echo "${B}PAIR CODE (secret) — paste once into the Foreign installer:${R}"
  echo "$PAIR_CODE"
  echo "${D}Stored mode 0600 at $ETC/pair-code.txt. Treat it like a password.${R}"
}

install_foreign() {
  ROLE="foreign"
  echo "Paste the v2 PAIR CODE generated on Iran, or leave blank for manual entry."
  read -r -p "PAIR CODE: " PAIR_CODE
  if [[ -n "$PAIR_CODE" ]]; then
    decode_pair_code "$PAIR_CODE" || die "Invalid/unsupported pair code."
    ok "Pair loaded: Iran=$IRAN_IP Domain=$DOMAIN Profile=$PROFILE"
  else
    prompt IRAN_IP "Iran server public IPv4"
    prompt FOREIGN_IP "This Foreign server public IPv4"
    prompt DOMAIN "Tunnel domain"
    prompt PROFILE "Profile name" "normal"
    prompt CONTROL_PORT "FRP WSS/TLS control port" "8443"
    prompt PUBLIC_PORT "Public user port on Iran" "443"
    prompt_secret TOKEN "Shared 64-hex FRP token"
  fi

  prompt LOCAL_TARGET_IP "Foreign Xray/local inbound listen IP" "127.0.0.1"
  prompt LOCAL_TARGET_PORT "Foreign Xray/local inbound port" "443"
  prompt POOL_COUNT "Pre-established independent work connections" "24"

  valid_ipv4 "$IRAN_IP" || die "Invalid Iran IPv4."
  valid_ipv4 "$FOREIGN_IP" || die "Invalid Foreign IPv4."
  valid_domain "$DOMAIN" || die "Invalid domain."
  valid_profile "$PROFILE" || die "Invalid profile."
  valid_port "$CONTROL_PORT" || die "Invalid control port."
  valid_port "$PUBLIC_PORT" || die "Invalid public user port."
  valid_local_host "$LOCAL_TARGET_IP" || die "Local target must be localhost/loopback IPv4/::1 in v2."
  valid_port "$LOCAL_TARGET_PORT" || die "Invalid local target port."
  [[ "$POOL_COUNT" =~ ^[0-9]+$ ]] && ((10#$POOL_COUNT >= 4 && 10#$POOL_COUNT <= 64)) || die "Pool count must be 4..64."
  [[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] || die "Token must be 64 lowercase hex characters."

  maybe_confirm_reconfigure
  check_domain_points_to_iran

  timeout 3 bash -c "</dev/tcp/${LOCAL_TARGET_IP}/${LOCAL_TARGET_PORT}" 2>/dev/null ||
    die "Local target ${LOCAL_TARGET_IP}:${LOCAL_TARGET_PORT} is not accepting TCP. Nothing was changed."

  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || die "System CA bundle is missing."
  timeout 8 openssl s_client \
      -connect "${DOMAIN}:${CONTROL_PORT}" \
      -servername "$DOMAIN" \
      -CAfile /etc/ssl/certs/ca-certificates.crt \
      -verify_return_error </dev/null >/dev/null 2>&1 ||
    die "TLS verification to ${DOMAIN}:${CONTROL_PORT} failed. Do not disable verification; fix DNS/certificate first."

  write_token
  write_frpc_config
  write_meta
  write_systemd

  systemctl restart "$SERVICE"
  sleep 3
  systemctl is-active --quiet "$SERVICE" || {
    journalctl -u "$SERVICE" -n 100 --no-pager
    die "frpc failed to start."
  }
  ok "Foreign node service started."
}

post_health() {
  echo
  info "Running final health gate..."
  set +e
  "$PANEL" health
  rc=$?
  set -e
  if [[ "$ROLE" == "iran" && "$rc" -eq 2 ]]; then
    echo
    ok "Iran control plane is ready; public proxy is waiting for the Foreign node."
    return 0
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo
    warn "Installation files are present, but STATUS is not READY."
    warn "Run: frp-tunnel diagnostics"
    return "$rc"
  fi
  echo
  ok "STATUS: READY FOR TRAFFIC"
}

main() {
  local role selected_role existing_role=""
  banner
  check_os

  echo "Choose this server's role:"
  echo "  1) IRAN    — frps; users connect here"
  echo "  2) FOREIGN — frpc; forwards to existing local Xray/3x-ui"
  read -r -p "Role [1/2]: " role
  case "$role" in
    1|iran|IRAN) selected_role="iran" ;;
    2|foreign|FOREIGN) selected_role="foreign" ;;
    *) die "Invalid role." ;;
  esac

  RECONFIG_APPROVED=0
  if systemctl is-active --quiet "$SERVICE"; then
    if [[ -r "$ETC/meta.env" ]]; then
      existing_role="$(sed -n 's/^ROLE=//p' "$ETC/meta.env" | tr -d "'\"" | head -n1)"
      [[ -z "$existing_role" || "$existing_role" == "$selected_role" ]] ||
        die "Existing service role is $existing_role; refusing to reconfigure it as $selected_role."
    fi
    echo
    warn "Active ${BRAND} detected. Nothing has been downloaded or overwritten yet."
    read -r -p "Type APPLY to allow a validated in-place reconfiguration: " ans
    [[ "$ans" == "APPLY" ]] || die "No changes made."
    RECONFIG_APPROVED=1
  fi

  install_deps
  backup_existing
  download_frp
  install_panel

  case "$selected_role" in
    iran) install_iran ;;
    foreign) install_foreign ;;
  esac
  post_health
  echo
  info "Management CLI: ${B}frp-tunnel${R}"
}

main "$@"

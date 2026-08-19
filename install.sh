#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="backhaul-ha-installer"
PROJECT_VERSION="1.0.0"
BACKHAUL_VERSION="v0.7.2"
BACKHAUL_BINARY_SHA256="7f1b1439d7fe1d15ae0b376e15614fe13d8a12f6e07a90263e310ea2a9d601fb"
BACKHAUL_ASSET="backhaul_linux_amd64.tar.gz"
BACKHAUL_URL="https://github.com/Musixal/Backhaul/releases/download/${BACKHAUL_VERSION}/${BACKHAUL_ASSET}"
XUI_VERSION="v2.9.4"
DEFAULT_PANEL_PORT="2095"
DEFAULT_DOMAIN="bh2.biya2film.top"
DEFAULT_INSTALLER_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/main/install.sh"
INSTALLER_URL="${BACKHAUL_HA_INSTALLER_URL:-$DEFAULT_INSTALLER_URL}"

ROLE=""
IRAN_IP=""
FOREIGN_IP=""
DOMAIN=""
BUNDLE=""
INSTALL_XUI="ask"
PANEL_PORT="$DEFAULT_PANEL_PORT"
NON_INTERACTIVE=0
SKIP_DNS_CHECK=0

C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'

log()  { printf "%b[+]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
info() { printf "%b[i]%b %s\n" "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf "%b[!]%b %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf "%b[x]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
backhaul-ha-installer 1.0.0

Usage:
  bash install.sh
  bash install.sh --role iran --iran-ip IP --foreign-ip IP --domain DOMAIN
  bash install.sh --role foreign --bundle /root/backhaul-ha-secrets.env

Options:
  --role iran|foreign
  --iran-ip IP
  --foreign-ip IP
  --domain DOMAIN
  --bundle PATH
  --install-xui yes|no
  --panel-port PORT
  --non-interactive
  --skip-dns-check
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --iran-ip) IRAN_IP="${2:-}"; shift 2 ;;
    --foreign-ip) FOREIGN_IP="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --install-xui) INSTALL_XUI="${2:-}"; shift 2 ;;
    --panel-port) PANEL_PORT="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this installer as root."
}

require_supported_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Ubuntu/Debian only. Detected: ${ID:-unknown}" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "This exact build is pinned to Backhaul v0.7.2 amd64." ;;
  esac
}

prompt() {
  local __var="$1" __text="$2" __default="${3:-}" value=""
  [[ -n "${!__var:-}" ]] && return 0
  [[ "$NON_INTERACTIVE" -eq 0 ]] || die "Missing required value: $__var"
  if [[ -n "$__default" ]]; then
    read -r -p "$__text [$__default]: " value
    value="${value:-$__default}"
  else
    read -r -p "$__text: " value
  fi
  printf -v "$__var" '%s' "$value"
}

ask_yes_no() {
  local question="$1" default="${2:-y}" answer=""
  [[ "$NON_INTERACTIVE" -eq 0 ]] || { [[ "$default" == "y" ]]; return; }
  if [[ "$default" == "y" ]]; then
    read -r -p "$question [Y/n]: " answer
    answer="${answer:-y}"
  else
    read -r -p "$question [y/N]: " answer
    answer="${answer:-n}"
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

valid_ipv4() {
  local ip="$1" IFS=. octets o
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$o >= 0 && 10#$o <= 255)) || return 1
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_token() {
  [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]
}

bundle_value() {
  local key="$1" file="$2"
  sed -n "s/^${key}='\([^']*\)'$/\1/p" "$file" | head -n1
}

install_packages() {
  log "Installing required packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates tar openssl ufw python3 netcat-openbsd
}

install_backhaul() {
  if [[ -x /usr/local/bin/backhaul ]]; then
    local existing
    existing="$(sha256sum /usr/local/bin/backhaul | awk '{print $1}')"
    if [[ "$existing" == "$BACKHAUL_BINARY_SHA256" ]]; then
      log "Backhaul ${BACKHAUL_VERSION} already installed with expected hash."
      return 0
    fi
    warn "Replacing existing Backhaul with pinned ${BACKHAUL_VERSION}."
  fi

  local tmpdir got_hash
  tmpdir="$(mktemp -d)"
  log "Downloading Backhaul ${BACKHAUL_VERSION}..."
  curl -fL --retry 4 --retry-delay 2 "$BACKHAUL_URL" -o "$tmpdir/$BACKHAUL_ASSET"
  tar -xzf "$tmpdir/$BACKHAUL_ASSET" -C "$tmpdir"
  [[ -f "$tmpdir/backhaul" ]] || { rm -rf "$tmpdir"; die "Archive does not contain ./backhaul"; }
  got_hash="$(sha256sum "$tmpdir/backhaul" | awk '{print $1}')"
  [[ "$got_hash" == "$BACKHAUL_BINARY_SHA256" ]] || { rm -rf "$tmpdir"; die "Backhaul hash mismatch."; }
  install -m 0755 "$tmpdir/backhaul" /usr/local/bin/backhaul
  rm -rf "$tmpdir"
  log "Backhaul installed and SHA256 verified."
}

backup_if_exists() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  local ts dest
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="/root/backhaul-ha-backups/$ts"
  mkdir -p "$dest"
  cp -a "$path" "$dest/" 2>/dev/null || true
  info "Backed up $path to $dest/"
}

write_common_tunnelctl() {
  install -d -m 0755 /etc/backhaul-ha
  printf '%s\n' "$ROLE" > /etc/backhaul-ha/role
  printf '%s\n' "$DOMAIN" > /etc/backhaul-ha/domain

  cat > /usr/local/bin/tunnelctl <<'CTL'
#!/usr/bin/env bash
set -u
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || echo unknown)"
DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || echo unknown)"
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'

valid_ipv4() {
  local ip="$1" IFS=. octets o
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$o >= 0 && 10#$o <= 255)) || return 1
  done
}

bundle_get() {
  local key="$1" file="/root/backhaul-ha-secrets.env"
  sed -n "s/^${key}='\([^']*\)'$/\1/p" "$file" | head -n1
}

bundle_set() {
  local key="$1" value="$2" file="/root/backhaul-ha-secrets.env"
  [[ -f "$file" ]] || { echo "Missing $file"; return 1; }
  sed -i "s|^${key}='[^']*'$|${key}='${value}'|" "$file"
  chmod 600 "$file"
}

service_line() {
  local s="$1"
  if systemctl is-active --quiet "$s"; then
    printf "%bOK%b   %s\n" "$G" "$N" "$s"
  else
    printf "%bDOWN%b %s\n" "$R" "$N" "$s"
  fi
}

http_line() {
  local name="$1" url="$2"
  if curl -fsS --max-time 4 "$url" >/dev/null 2>&1; then
    printf "%bOK%b   %s\n" "$G" "$N" "$name"
  else
    printf "%bFAIL%b %s\n" "$R" "$N" "$name"
  fi
}

cmd="${1:-status}"
case "$cmd" in
  status)
    echo "Role: $ROLE"
    echo "Domain: $DOMAIN"
    if [[ "$ROLE" == "iran" ]]; then
      service_line backhaul
      service_line backhaul-wss
      service_line haproxy
      http_line "WSS end-to-end health :10444" "http://127.0.0.1:10444/healthz"
      http_line "TCP end-to-end health :11444" "http://127.0.0.1:11444/healthz"
      echo
      ss -lntp 2>/dev/null | grep -E ':443|:8443|:10443|:10444|:11443|:11444|:3080' || true
    elif [[ "$ROLE" == "foreign" ]]; then
      service_line backhaul
      service_line backhaul-wss
      service_line backhaul-health
      http_line "Local health :18090" "http://127.0.0.1:18090/healthz"
      if ss -lntp 2>/dev/null | grep -q '127\.0\.0\.1:443'; then
        printf "%bOK%b   local listener on 127.0.0.1:443\n" "$G" "$N"
      else
        printf "%bWARN%b no listener on 127.0.0.1:443\n" "$Y" "$N"
      fi
    fi
    ;;
  test)
    if [[ "$ROLE" == "iran" ]]; then
      haproxy -c -f /etc/haproxy/haproxy.cfg || exit 1
      curl -fsS --max-time 5 http://127.0.0.1:10444/healthz && echo
      curl -fsS --max-time 5 http://127.0.0.1:11444/healthz && echo
    elif [[ "$ROLE" == "foreign" ]]; then
      curl -fsS --max-time 5 http://127.0.0.1:18090/healthz && echo
    fi
    ;;
  restart)
    if [[ "$ROLE" == "iran" ]]; then
      systemctl restart backhaul backhaul-wss haproxy
    elif [[ "$ROLE" == "foreign" ]]; then
      systemctl restart backhaul backhaul-wss backhaul-health
    fi
    sleep 3
    "$0" status
    ;;
  logs)
    if [[ "$ROLE" == "iran" ]]; then
      journalctl -u backhaul -u backhaul-wss -u haproxy -n 100 --no-pager
    else
      journalctl -u backhaul -u backhaul-wss -u backhaul-health -n 100 --no-pager
    fi
    ;;
  replace-foreign)
    [[ "$ROLE" == "iran" ]] || { echo "replace-foreign must run on Iran."; exit 2; }
    new_ip="${2:-}"
    valid_ipv4 "$new_ip" || { echo "Usage: tunnelctl replace-foreign NEW_FOREIGN_IP"; exit 2; }
    old_ip="$(bundle_get FOREIGN_IP)"
    if [[ -n "$old_ip" ]]; then
      ufw delete allow from "$old_ip" to any port 3080 proto tcp >/dev/null 2>&1 || true
    fi
    ufw allow from "$new_ip" to any port 3080 proto tcp comment 'Backhaul TCPMux control'
    bundle_set FOREIGN_IP "$new_ip"
    echo "Foreign IP updated: ${old_ip:-unknown} -> $new_ip"
    echo "Now copy /root/backhaul-ha-secrets.env to the new Foreign server and run the installer there."
    ;;
  replace-iran)
    [[ "$ROLE" == "foreign" ]] || { echo "replace-iran must run on Foreign."; exit 2; }
    new_ip="${2:-}"
    valid_ipv4 "$new_ip" || { echo "Usage: tunnelctl replace-iran NEW_IRAN_IP"; exit 2; }
    old_ip="$(bundle_get IRAN_IP)"
    sed -i -E "s|^remote_addr = \"[0-9.]+:3080\"$|remote_addr = \"$new_ip:3080\"|" /etc/backhaul/client.toml
    bundle_set IRAN_IP "$new_ip"
    systemctl restart backhaul backhaul-wss
    echo "Iran IP updated: ${old_ip:-unknown} -> $new_ip"
    echo "Update the backbone DNS A record to $new_ip, then copy /root/backhaul-ha-secrets.env to the new Iran server."
    ;;
  *)
    echo "Usage: tunnelctl {status|test|restart|logs|replace-foreign NEW_IP|replace-iran NEW_IP}"
    exit 2
    ;;
esac
CTL
  chmod 0755 /usr/local/bin/tunnelctl
}

get_ssh_port() {
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  printf '%s\n' "${p:-22}"
}

configure_iran_firewall() {
  local ssh_port
  ssh_port="$(get_ssh_port)"
  log "Configuring UFW on Iran..."
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$ssh_port/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'Certbot HTTP-01'
  ufw allow 443/tcp comment 'HAProxy public HTTPS'
  ufw allow from "$FOREIGN_IP" to any port 3080 proto tcp comment 'Backhaul TCPMux control'
  ufw --force enable
}

ensure_certificate() {
  local cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  local key="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  if [[ -s "$cert" && -s "$key" ]]; then
    log "Existing certificate found for $DOMAIN."
    return 0
  fi

  apt-get install -y certbot
  if [[ "$SKIP_DNS_CHECK" -eq 0 ]]; then
    local resolved
    resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ "$resolved" == "$IRAN_IP" ]] || die "$DOMAIN resolves to ${resolved:-nothing}, expected $IRAN_IP. Update DNS or use --skip-dns-check."
  fi

  if ss -lntp | grep -q ':80 '; then
    die "Port 80 is already in use; Certbot standalone cannot bind it."
  fi

  log "Requesting Let's Encrypt certificate for $DOMAIN..."
  certbot certonly --standalone -d "$DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive
  [[ -s "$cert" && -s "$key" ]] || die "Certificate was not created."
}

load_or_create_tokens() {
  local saved="/root/backhaul-ha-secrets.env"
  TCP_TOKEN="${TCP_TOKEN:-}"
  WSS_TOKEN="${WSS_TOKEN:-}"

  if [[ -f "$saved" ]]; then
    local old_tcp old_wss
    old_tcp="$(bundle_value TCP_TOKEN "$saved")"
    old_wss="$(bundle_value WSS_TOKEN "$saved")"
    valid_token "$old_tcp" && TCP_TOKEN="$old_tcp" || true
    valid_token "$old_wss" && WSS_TOKEN="$old_wss" || true
  fi

  valid_token "$TCP_TOKEN" || TCP_TOKEN="$(openssl rand -hex 32)"
  valid_token "$WSS_TOKEN" || WSS_TOKEN="$(openssl rand -hex 32)"
}

write_bundle() {
  cat > /root/backhaul-ha-secrets.env <<EOF
IRAN_IP='$IRAN_IP'
FOREIGN_IP='$FOREIGN_IP'
DOMAIN='$DOMAIN'
TCP_TOKEN='$TCP_TOKEN'
WSS_TOKEN='$WSS_TOKEN'
EOF
  chmod 0600 /root/backhaul-ha-secrets.env
}

write_iran_configs() {
  install -d -m 0700 /etc/backhaul
  backup_if_exists /etc/backhaul/server.toml
  backup_if_exists /etc/backhaul/server-wss.toml
  backup_if_exists /etc/haproxy/haproxy.cfg

  cat > /etc/backhaul/server.toml <<CFG
[server]
bind_addr = "0.0.0.0:3080"
transport = "tcpmux"
token = "$TCP_TOKEN"

keepalive_period = 75
heartbeat = 40
nodelay = true
channel_size = 2048

mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536

sniffer = false
web_port = 0
log_level = "debug"

ports = [
    "11443=127.0.0.1:443",
    "11444=127.0.0.1:18090"
]
CFG

  cat > /etc/backhaul/server-wss.toml <<CFG
[server]
bind_addr = "127.0.0.1:8443"
transport = "wssmux"
token = "$WSS_TOKEN"

keepalive_period = 75
heartbeat = 40
nodelay = true
channel_size = 2048

mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536

tls_cert = "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
tls_key = "/etc/letsencrypt/live/$DOMAIN/privkey.pem"

sniffer = false
web_port = 0
log_level = "debug"

ports = [
    "10443=127.0.0.1:443",
    "10444=127.0.0.1:18090"
]
CFG

  chmod 0600 /etc/backhaul/server.toml /etc/backhaul/server-wss.toml

  cat > /etc/systemd/system/backhaul.service <<'UNIT'
[Unit]
Description=Backhaul TCPMux Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/server.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  cat > /etc/systemd/system/backhaul-wss.service <<'UNIT'
[Unit]
Description=Backhaul WSSMux Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/server-wss.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  apt-get install -y haproxy

  cat > /etc/haproxy/haproxy.cfg <<CFG
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 50000
    daemon
    user haproxy
    group haproxy

defaults
    log global
    mode tcp
    option tcplog

    timeout connect 5s
    timeout client 1m
    timeout server 1m
    timeout check 3s

frontend https_mux
    bind *:443
    mode tcp

    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

    acl is_backbone req.ssl_sni -i $DOMAIN

    use_backend backhaul_wss if is_backbone
    default_backend vpn_users

backend backhaul_wss
    mode tcp
    server wss_control 127.0.0.1:8443

backend vpn_users
    mode tcp

    option redispatch
    retries 2

    option httpchk
    http-check send meth GET uri /healthz ver HTTP/1.1 hdr Host localhost
    http-check expect status 200

    server wss_primary 127.0.0.1:10443 check port 10444 inter 2s fall 2 rise 2 on-marked-down shutdown-sessions
    server tcp_backup 127.0.0.1:11443 check port 11444 inter 2s fall 2 rise 2 backup
CFG

  haproxy -c -f /etc/haproxy/haproxy.cfg
  systemctl daemon-reload
  systemctl enable backhaul backhaul-wss haproxy >/dev/null
  systemctl restart backhaul backhaul-wss haproxy
}

install_iran() {
  if [[ -n "$BUNDLE" ]]; then
    local cli_iran="$IRAN_IP" cli_foreign="$FOREIGN_IP" cli_domain="$DOMAIN"
    load_bundle
    [[ -n "$cli_iran" ]] && IRAN_IP="$cli_iran"
    [[ -n "$cli_foreign" ]] && FOREIGN_IP="$cli_foreign"
    [[ -n "$cli_domain" ]] && DOMAIN="$cli_domain"
    info "Using existing bundle to preserve tunnel tokens."
  fi

  prompt IRAN_IP "Iran public IPv4"
  prompt FOREIGN_IP "Foreign public IPv4"
  prompt DOMAIN "Backbone domain (A record must point to Iran)" "$DEFAULT_DOMAIN"

  valid_ipv4 "$IRAN_IP" || die "Invalid Iran IPv4: $IRAN_IP"
  valid_ipv4 "$FOREIGN_IP" || die "Invalid Foreign IPv4: $FOREIGN_IP"
  valid_domain "$DOMAIN" || die "Invalid backbone domain: $DOMAIN"

  install_packages
  install_backhaul
  configure_iran_firewall
  ensure_certificate
  load_or_create_tokens
  write_bundle
  write_iran_configs
  ROLE="iran"
  write_common_tunnelctl

  echo
  log "Iran side installed."
  tunnelctl status || true
  echo
  printf "%bNEXT STEP ON FOREIGN%b\n" "$C_CYAN" "$C_RESET"
  echo "1) Copy bundle:"
  echo "   scp /root/backhaul-ha-secrets.env root@$FOREIGN_IP:/root/backhaul-ha-secrets.env"
  echo
  echo "2) Install Foreign:"
  echo "   bash <(curl -fsSL '$INSTALLER_URL') --role foreign --bundle /root/backhaul-ha-secrets.env"
  echo
}

load_bundle() {
  [[ -n "$BUNDLE" ]] || BUNDLE="/root/backhaul-ha-secrets.env"
  [[ -f "$BUNDLE" ]] || die "Bundle not found: $BUNDLE"
  chmod 0600 "$BUNDLE" 2>/dev/null || true

  IRAN_IP="$(bundle_value IRAN_IP "$BUNDLE")"
  FOREIGN_IP="$(bundle_value FOREIGN_IP "$BUNDLE")"
  DOMAIN="$(bundle_value DOMAIN "$BUNDLE")"
  TCP_TOKEN="$(bundle_value TCP_TOKEN "$BUNDLE")"
  WSS_TOKEN="$(bundle_value WSS_TOKEN "$BUNDLE")"

  valid_ipv4 "$IRAN_IP" || die "Invalid Iran IP in bundle."
  valid_ipv4 "$FOREIGN_IP" || die "Invalid Foreign IP in bundle."
  valid_domain "$DOMAIN" || die "Invalid domain in bundle."
  valid_token "$TCP_TOKEN" || die "Invalid TCP token in bundle."
  valid_token "$WSS_TOKEN" || die "Invalid WSS token in bundle."
}

install_xui_optional() {
  if command -v x-ui >/dev/null 2>&1; then
    info "x-ui already exists; leaving it untouched."
    return 0
  fi

  local do_install=0
  case "$INSTALL_XUI" in
    yes|y|true|1) do_install=1 ;;
    no|n|false|0) do_install=0 ;;
    ask)
      if ask_yes_no "3x-ui not found. Launch official pinned 3x-ui $XUI_VERSION installer?" n; then
        do_install=1
      fi
      ;;
    *) die "--install-xui must be yes or no" ;;
  esac

  if [[ "$do_install" -eq 1 ]]; then
    log "Launching official 3x-ui $XUI_VERSION installer..."
    bash <(curl -Ls "https://raw.githubusercontent.com/mhsanaei/3x-ui/$XUI_VERSION/install.sh") "$XUI_VERSION"
    warn "x-ui.db is NOT overwritten/imported by this project."
  else
    warn "Skipping 3x-ui. VPN needs Xray/local service on 127.0.0.1:443."
  fi
}

configure_foreign_firewall() {
  local ssh_port
  ssh_port="$(get_ssh_port)"
  valid_port "$PANEL_PORT" || die "Invalid panel port: $PANEL_PORT"
  log "Configuring UFW on Foreign..."
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$ssh_port/tcp" comment 'SSH'
  ufw allow "$PANEL_PORT/tcp" comment '3x-ui panel'
  ufw --force enable
}

write_foreign_configs() {
  install -d -m 0700 /etc/backhaul
  backup_if_exists /etc/backhaul/client.toml
  backup_if_exists /etc/backhaul/client-wss.toml

  cat > /etc/backhaul/client.toml <<CFG
[client]
remote_addr = "$IRAN_IP:3080"
transport = "tcpmux"
token = "$TCP_TOKEN"

connection_pool = 8
aggressive_pool = false

keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true

mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536

sniffer = false
web_port = 0
log_level = "debug"
CFG

  cat > /etc/backhaul/client-wss.toml <<CFG
[client]
remote_addr = "$DOMAIN:443"
edge_ip = ""
transport = "wssmux"
token = "$WSS_TOKEN"

connection_pool = 8
aggressive_pool = false

keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true

mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536

sniffer = false
web_port = 0
log_level = "debug"
CFG

  chmod 0600 /etc/backhaul/client.toml /etc/backhaul/client-wss.toml

  cat > /etc/systemd/system/backhaul.service <<'UNIT'
[Unit]
Description=Backhaul TCPMux Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/client.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  cat > /etc/systemd/system/backhaul-wss.service <<'UNIT'
[Unit]
Description=Backhaul WSSMux Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/client-wss.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  install -d -m 0755 /opt/backhaul-health
  printf 'OK\n' > /opt/backhaul-health/healthz

  cat > /etc/systemd/system/backhaul-health.service <<'UNIT'
[Unit]
Description=Backhaul Health HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 18090 --bind 127.0.0.1 --directory /opt/backhaul-health
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable backhaul backhaul-wss backhaul-health >/dev/null
  systemctl restart backhaul-health backhaul backhaul-wss
}

wait_for_control_channels() {
  local tries=15 ok_tcp=0 ok_wss=0 i
  info "Waiting for Backhaul control channels..."
  for ((i=1; i<=tries; i++)); do
    journalctl -u backhaul -n 30 --no-pager 2>/dev/null | grep -q 'control channel established successfully' && ok_tcp=1 || true
    journalctl -u backhaul-wss -n 30 --no-pager 2>/dev/null | grep -q 'control channel established successfully' && ok_wss=1 || true
    [[ "$ok_tcp" -eq 1 && "$ok_wss" -eq 1 ]] && break
    sleep 1
  done
  [[ "$ok_tcp" -eq 1 ]] && log "TCPMux control channel established." || warn "TCPMux control channel not confirmed yet."
  [[ "$ok_wss" -eq 1 ]] && log "WSSMux control channel established." || warn "WSSMux control channel not confirmed yet."
}

install_foreign() {
  load_bundle
  install_packages
  install_backhaul
  install_xui_optional
  configure_foreign_firewall
  write_foreign_configs
  ROLE="foreign"
  write_common_tunnelctl
  wait_for_control_channels

  echo
  log "Foreign side installed."
  tunnelctl status || true
  echo
  if ss -lntp 2>/dev/null | grep -q '127\.0\.0\.1:443'; then
    log "Local listener found on 127.0.0.1:443."
  else
    warn "No listener on 127.0.0.1:443 yet. Restore/import 3x-ui/Xray."
  fi
}

main() {
  require_root
  require_supported_os

  if [[ -z "$ROLE" ]]; then
    [[ "$NON_INTERACTIVE" -eq 0 ]] || die "--role is required."
    echo "Backhaul HA Installer $PROJECT_VERSION"
    echo "1) Iran"
    echo "2) Foreign"
    local choice
    read -r -p "Select role [1/2]: " choice
    case "$choice" in
      1|iran|IRAN) ROLE="iran" ;;
      2|foreign|FOREIGN) ROLE="foreign" ;;
      *) die "Invalid role selection." ;;
    esac
  fi

  case "$ROLE" in
    iran) install_iran ;;
    foreign) install_foreign ;;
    *) die "Role must be iran or foreign." ;;
  esac
}

main

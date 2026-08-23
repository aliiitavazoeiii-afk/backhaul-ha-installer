#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.2.0"
ROLE=""
IRAN_IP=""
FOREIGN_A_IP=""
FOREIGN_B_IP=""
DOMAIN_A=""
DOMAIN_B=""
BUNDLE=""
SKIP_DNS_CHECK=0
REPLACE_EXISTING=0

BACKHAUL_VERSION="v0.7.2"
BACKHAUL_SHA256="7f1b1439d7fe1d15ae0b376e15614fe13d8a12f6e07a90263e310ea2a9d601fb"
BACKHAUL_ASSET="backhaul_linux_amd64.tar.gz"
BACKHAUL_URL="https://github.com/Musixal/Backhaul/releases/download/${BACKHAUL_VERSION}/${BACKHAUL_ASSET}"
BIN="/usr/local/bin/backhaul-dual"
CFGDIR="/etc/dual-backhaul"
STATEDIR="/etc/dual-backhaul-ha"

log(){ printf '[+] %s\n' "$*"; }
info(){ printf '[i] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

usage(){
cat <<'EOF'
Dual-Foreign Active/Active Backhaul installer

Iran:
  bash install-dual.sh --role iran \
    --iran-ip IRAN_IP \
    --foreign-a-ip FOREIGN_A_IP \
    --foreign-b-ip FOREIGN_B_IP \
    --domain-a DOMAIN_A \
    --domain-b DOMAIN_B \
    [--replace-existing-tunnel]

Foreign A:
  bash install-dual.sh --role foreign-a --bundle /root/dual-backhaul-foreign-a.env [--replace-existing-tunnel]

Foreign B:
  bash install-dual.sh --role foreign-b --bundle /root/dual-backhaul-foreign-b.env [--replace-existing-tunnel]

Options:
  --skip-dns-check
  --replace-existing-tunnel   disable known old backhaul* services before binding project ports
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --iran-ip) IRAN_IP="${2:-}"; shift 2;;
    --foreign-a-ip) FOREIGN_A_IP="${2:-}"; shift 2;;
    --foreign-b-ip) FOREIGN_B_IP="${2:-}"; shift 2;;
    --domain-a) DOMAIN_A="${2:-}"; shift 2;;
    --domain-b) DOMAIN_B="${2:-}"; shift 2;;
    --bundle) BUNDLE="${2:-}"; shift 2;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift;;
    --replace-existing-tunnel) REPLACE_EXISTING=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."
[[ "$ROLE" == "iran" || "$ROLE" == "foreign-a" || "$ROLE" == "foreign-b" ]] || die "--role must be iran, foreign-a or foreign-b"

source /etc/os-release 2>/dev/null || die "Cannot detect OS"
case "${ID:-}" in ubuntu|debian) ;; *) die "Ubuntu/Debian only";; esac
case "$(uname -m)" in x86_64|amd64) ;; *) die "amd64 only";; esac

valid_ipv4(){
  local ip="$1" IFS=. a o
  read -r -a a <<< "$ip"
  [[ ${#a[@]} -eq 4 ]] || return 1
  for o in "${a[@]}"; do [[ "$o" =~ ^[0-9]{1,3}$ ]] && ((10#$o<=255)) || return 1; done
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_token(){ [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]; }
bget(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$2" | head -n1; }

install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  if [[ "$ROLE" == iran ]]; then
    apt-get install -y curl ca-certificates tar openssl haproxy certbot ufw
  else
    apt-get install -y curl ca-certificates tar openssl python3
  fi
}

install_binary(){
  if [[ -x "$BIN" ]] && [[ "$(sha256sum "$BIN" | awk '{print $1}')" == "$BACKHAUL_SHA256" ]]; then
    log "Pinned Backhaul already installed at $BIN"
    return
  fi
  local d got
  d="$(mktemp -d)"
  curl -fL --retry 4 --retry-delay 2 "$BACKHAUL_URL" -o "$d/$BACKHAUL_ASSET"
  tar -xzf "$d/$BACKHAUL_ASSET" -C "$d"
  [[ -f "$d/backhaul" ]] || { rm -rf "$d"; die "Backhaul archive invalid"; }
  got="$(sha256sum "$d/backhaul" | awk '{print $1}')"
  [[ "$got" == "$BACKHAUL_SHA256" ]] || { rm -rf "$d"; die "Backhaul SHA256 mismatch"; }
  install -m 0755 "$d/backhaul" "$BIN"
  rm -rf "$d"
}

stop_old_stack_if_requested(){
  (( REPLACE_EXISTING == 1 )) || return 0
  warn "Disabling known legacy Backhaul services; configs are preserved."
  local u
  for u in backhaul.service backhaul-wss.service backhaul-tcp.service backhaul-tcptls.service backhaul-wss-tls.service backhaul-wss-ab.service; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  done
}

unit(){
  local name="$1" desc="$2" cfg="$3"
  cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} -c ${cfg}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

server_mux_cfg(){
  local file="$1" bind="$2" token="$3" data="$4" health="$5"
  cat > "$file" <<EOF
[server]
bind_addr = "${bind}"
transport = "tcpmux"
token = "${token}"
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
log_level = "info"
ports = [
  "${data}=127.0.0.1:443",
  "${health}=127.0.0.1:18090"
]
EOF
}

server_tcp_cfg(){
  local file="$1" bind="$2" token="$3" data="$4" health="$5"
  cat > "$file" <<EOF
[server]
bind_addr = "${bind}"
transport = "tcp"
token = "${token}"
accept_udp = false
keepalive_period = 75
heartbeat = 40
nodelay = true
channel_size = 2048
sniffer = false
web_port = 0
log_level = "info"
ports = [
  "${data}=127.0.0.1:443",
  "${health}=127.0.0.1:18090"
]
EOF
}

server_wss_cfg(){
  local file="$1" bind="$2" token="$3" domain="$4" data="$5" health="$6"
  cat > "$file" <<EOF
[server]
bind_addr = "${bind}"
transport = "wssmux"
token = "${token}"
keepalive_period = 75
heartbeat = 40
nodelay = true
channel_size = 2048
mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
tls_cert = "/etc/letsencrypt/live/${domain}/fullchain.pem"
tls_key = "/etc/letsencrypt/live/${domain}/privkey.pem"
sniffer = false
web_port = 0
log_level = "info"
ports = [
  "${data}=127.0.0.1:443",
  "${health}=127.0.0.1:18090"
]
EOF
}

client_mux_cfg(){
  local file="$1" remote="$2" token="$3"
  cat > "$file" <<EOF
[client]
remote_addr = "${remote}"
transport = "tcpmux"
token = "${token}"
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
log_level = "info"
EOF
}

client_tcp_cfg(){
  local file="$1" remote="$2" token="$3"
  cat > "$file" <<EOF
[client]
remote_addr = "${remote}"
transport = "tcp"
token = "${token}"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true
sniffer = false
web_port = 0
log_level = "info"
EOF
}

client_wss_cfg(){
  local file="$1" remote="$2" token="$3"
  cat > "$file" <<EOF
[client]
remote_addr = "${remote}"
transport = "wssmux"
token = "${token}"
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
log_level = "info"
EOF
}

ensure_cert(){
  local domain="$1"
  if [[ -s "/etc/letsencrypt/live/${domain}/fullchain.pem" && -s "/etc/letsencrypt/live/${domain}/privkey.pem" ]]; then
    log "Existing certificate found for $domain"
    return
  fi
  if (( SKIP_DNS_CHECK == 0 )); then
    local r
    r="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ "$r" == "$IRAN_IP" ]] || die "$domain resolves to ${r:-nothing}; expected $IRAN_IP"
  fi
  if ss -lntp 2>/dev/null | grep -q ':80 '; then
    die "Port 80 is in use; cannot run certbot standalone for $domain"
  fi
  certbot certonly --standalone -d "$domain" --agree-tos --register-unsafely-without-email --non-interactive
}

write_haproxy(){
  mkdir -p /root/dual-backhaul-backups
  [[ -f /etc/haproxy/haproxy.cfg ]] && cp -a /etc/haproxy/haproxy.cfg "/root/dual-backhaul-backups/haproxy.$(date +%Y%m%d-%H%M%S).cfg"
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 100000

defaults
    log global
    mode tcp
    option dontlognull
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend public_https
    bind *:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    acl control_a req.ssl_sni -i ${DOMAIN_A}
    acl control_b req.ssl_sni -i ${DOMAIN_B}
    use_backend control_a_wss if control_a
    use_backend control_b_wss if control_b
    default_backend vpn_users

backend control_a_wss
    mode tcp
    server a_wss_control 127.0.0.1:8443

backend control_b_wss
    mode tcp
    server b_wss_control 127.0.0.1:8543

frontend slot_a
    bind 127.0.0.1:15001
    mode tcp
    default_backend slot_a_transports
backend slot_a_transports
    mode tcp
    option redispatch
    retries 2
    option httpchk GET /healthz
    http-check expect status 200
    server a_wss 127.0.0.1:10443 check port 10444 inter 3s fall 2 rise 3 on-marked-down shutdown-sessions
    server a_mux 127.0.0.1:11443 check port 11444 inter 3s fall 2 rise 3 backup
    server a_tcp 127.0.0.1:12443 check port 12444 inter 3s fall 2 rise 3 backup

frontend slot_b
    bind 127.0.0.1:15002
    mode tcp
    default_backend slot_b_transports
backend slot_b_transports
    mode tcp
    option redispatch
    retries 2
    option httpchk GET /healthz
    http-check expect status 200
    server b_wss 127.0.0.1:20443 check port 20444 inter 3s fall 2 rise 3 on-marked-down shutdown-sessions
    server b_mux 127.0.0.1:21443 check port 21444 inter 3s fall 2 rise 3 backup
    server b_tcp 127.0.0.1:22443 check port 22444 inter 3s fall 2 rise 3 backup

frontend slot_a_health
    bind 127.0.0.1:15011
    mode http
    http-request return status 200 content-type text/plain string OK if { nbsrv(slot_a_transports) gt 0 }
    http-request return status 503 content-type text/plain string DOWN
frontend slot_b_health
    bind 127.0.0.1:15012
    mode http
    http-request return status 200 content-type text/plain string OK if { nbsrv(slot_b_transports) gt 0 }
    http-request return status 503 content-type text/plain string DOWN

backend vpn_users
    mode tcp
    balance leastconn
    option httpchk GET /healthz
    http-check expect status 200
    server foreign_a 127.0.0.1:15001 check port 15011 inter 3s fall 2 rise 3
    server foreign_b 127.0.0.1:15002 check port 15012 inter 3s fall 2 rise 3
EOF
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null || die "Generated HAProxy config is invalid"
}

write_health_service(){
  install -d -m 0755 /opt/dual-backhaul-health
  cat > /opt/dual-backhaul-health/server.py <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Server(ThreadingHTTPServer):
    request_queue_size = 128
    daemon_threads = True
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/healthz':
            self.send_response(404); self.end_headers(); return
        body=b'OK\n'
        self.send_response(200)
        self.send_header('Content-Type','text/plain')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def log_message(self, *_): pass
Server(('127.0.0.1',18090), H).serve_forever()
PY
  cat > /etc/systemd/system/dual-bh-health.service <<'EOF'
[Unit]
Description=Dual Backhaul local health endpoint
After=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/dual-backhaul-health/server.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
}

write_diag(){
cat > /usr/local/bin/dual-diagnose <<'EOF'
#!/usr/bin/env bash
set -u
ROLE="$(cat /etc/dual-backhaul-ha/role 2>/dev/null || echo unknown)"
ok(){ echo "[OK]   $*"; }
fail(){ echo "[FAIL] $*"; }
svc(){ systemctl is-active --quiet "$1" && ok "$1 active" || fail "$1 down"; }
h(){ local c; c="$(curl -sS -o /dev/null --max-time 4 -w '%{http_code}' "$2" 2>/dev/null || true)"; [[ "$c" == 200 ]] && ok "$1" || fail "$1 HTTP=${c:-000}"; }
echo "Dual-Foreign Diagnose"
echo "Role: $ROLE"
if [[ "$ROLE" == iran ]]; then
  for s in dual-bh-a-wss dual-bh-a-mux dual-bh-a-tcp dual-bh-b-wss dual-bh-b-mux dual-bh-b-tcp haproxy; do svc "$s"; done
  h 'A WSS health' http://127.0.0.1:10444/healthz
  h 'A MUX health' http://127.0.0.1:11444/healthz
  h 'A TCP health' http://127.0.0.1:12444/healthz
  h 'A aggregate slot' http://127.0.0.1:15011/healthz
  h 'B WSS health' http://127.0.0.1:20444/healthz
  h 'B MUX health' http://127.0.0.1:21444/healthz
  h 'B TCP health' http://127.0.0.1:22444/healthz
  h 'B aggregate slot' http://127.0.0.1:15012/healthz
else
  svc dual-bh-health
  svc dual-bh-wss
  svc dual-bh-mux
  svc dual-bh-tcp
  h 'local health' http://127.0.0.1:18090/healthz
  ss -lntp 2>/dev/null | grep -q '127.0.0.1:443' && ok 'Xray listener 127.0.0.1:443 present' || fail 'Xray listener 127.0.0.1:443 missing'
fi
EOF
chmod 0755 /usr/local/bin/dual-diagnose
}

install_packages
install_binary
stop_old_stack_if_requested
install -d -m 0700 "$CFGDIR" "$STATEDIR"

if [[ "$ROLE" == iran ]]; then
  valid_ipv4 "$IRAN_IP" || die "Invalid --iran-ip"
  valid_ipv4 "$FOREIGN_A_IP" || die "Invalid --foreign-a-ip"
  valid_ipv4 "$FOREIGN_B_IP" || die "Invalid --foreign-b-ip"
  valid_domain "$DOMAIN_A" || die "Invalid --domain-a"
  valid_domain "$DOMAIN_B" || die "Invalid --domain-b"
  [[ "$DOMAIN_A" != "$DOMAIN_B" ]] || die "DOMAIN_A and DOMAIN_B must differ"

  ensure_cert "$DOMAIN_A"
  ensure_cert "$DOMAIN_B"

  A_WSS="$(openssl rand -hex 32)"; A_MUX="$(openssl rand -hex 32)"; A_TCP="$(openssl rand -hex 32)"
  B_WSS="$(openssl rand -hex 32)"; B_MUX="$(openssl rand -hex 32)"; B_TCP="$(openssl rand -hex 32)"

  cat > /root/dual-backhaul-foreign-a.env <<EOF
ROLE='foreign-a'
IRAN_IP='${IRAN_IP}'
FOREIGN_IP='${FOREIGN_A_IP}'
DOMAIN='${DOMAIN_A}'
WSS_TOKEN='${A_WSS}'
MUX_TOKEN='${A_MUX}'
TCP_TOKEN='${A_TCP}'
MUX_PORT='3080'
TCP_PORT='3081'
EOF
  cat > /root/dual-backhaul-foreign-b.env <<EOF
ROLE='foreign-b'
IRAN_IP='${IRAN_IP}'
FOREIGN_IP='${FOREIGN_B_IP}'
DOMAIN='${DOMAIN_B}'
WSS_TOKEN='${B_WSS}'
MUX_TOKEN='${B_MUX}'
TCP_TOKEN='${B_TCP}'
MUX_PORT='3180'
TCP_PORT='3181'
EOF
  chmod 0600 /root/dual-backhaul-foreign-a.env /root/dual-backhaul-foreign-b.env

  server_wss_cfg "$CFGDIR/a-wss.toml" "127.0.0.1:8443" "$A_WSS" "$DOMAIN_A" 10443 10444
  server_mux_cfg "$CFGDIR/a-mux.toml" "0.0.0.0:3080" "$A_MUX" 11443 11444
  server_tcp_cfg "$CFGDIR/a-tcp.toml" "0.0.0.0:3081" "$A_TCP" 12443 12444
  server_wss_cfg "$CFGDIR/b-wss.toml" "127.0.0.1:8543" "$B_WSS" "$DOMAIN_B" 20443 20444
  server_mux_cfg "$CFGDIR/b-mux.toml" "0.0.0.0:3180" "$B_MUX" 21443 21444
  server_tcp_cfg "$CFGDIR/b-tcp.toml" "0.0.0.0:3181" "$B_TCP" 22443 22444
  chmod 0600 "$CFGDIR"/*.toml

  unit dual-bh-a-wss 'Dual Backhaul Foreign-A WSSMux server' "$CFGDIR/a-wss.toml"
  unit dual-bh-a-mux 'Dual Backhaul Foreign-A TCPMux server' "$CFGDIR/a-mux.toml"
  unit dual-bh-a-tcp 'Dual Backhaul Foreign-A plain TCP server' "$CFGDIR/a-tcp.toml"
  unit dual-bh-b-wss 'Dual Backhaul Foreign-B WSSMux server' "$CFGDIR/b-wss.toml"
  unit dual-bh-b-mux 'Dual Backhaul Foreign-B TCPMux server' "$CFGDIR/b-mux.toml"
  unit dual-bh-b-tcp 'Dual Backhaul Foreign-B plain TCP server' "$CFGDIR/b-tcp.toml"

  write_haproxy
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 443/tcp comment 'Dual Backhaul public ingress' >/dev/null || true
    ufw allow 80/tcp comment 'Certbot HTTP-01' >/dev/null || true
    ufw allow from "$FOREIGN_A_IP" to any port 3080 proto tcp comment 'Dual A TCPMux' >/dev/null || true
    ufw allow from "$FOREIGN_A_IP" to any port 3081 proto tcp comment 'Dual A TCP' >/dev/null || true
    ufw allow from "$FOREIGN_B_IP" to any port 3180 proto tcp comment 'Dual B TCPMux' >/dev/null || true
    ufw allow from "$FOREIGN_B_IP" to any port 3181 proto tcp comment 'Dual B TCP' >/dev/null || true
  fi

  printf 'iran\n' > "$STATEDIR/role"
  cat > "$STATEDIR/topology.env" <<EOF
IRAN_IP='${IRAN_IP}'
FOREIGN_A_IP='${FOREIGN_A_IP}'
FOREIGN_B_IP='${FOREIGN_B_IP}'
DOMAIN_A='${DOMAIN_A}'
DOMAIN_B='${DOMAIN_B}'
EOF

  systemctl daemon-reload
  systemctl enable --now dual-bh-a-wss dual-bh-a-mux dual-bh-a-tcp dual-bh-b-wss dual-bh-b-mux dual-bh-b-tcp >/dev/null
  systemctl enable haproxy >/dev/null 2>&1 || true
  systemctl restart haproxy
  write_diag

  echo
  log "Iran Active/Active data-plane installed."
  info "Copy /root/dual-backhaul-foreign-a.env directly to Foreign A."
  info "Copy /root/dual-backhaul-foreign-b.env directly to Foreign B."
  info "Do not paste either bundle into chat/logs."
  info "After both Foreign installs: dual-diagnose"
else
  [[ -n "$BUNDLE" && -f "$BUNDLE" ]] || die "Missing --bundle file"
  EXPECTED="$(bget ROLE "$BUNDLE")"
  [[ "$EXPECTED" == "$ROLE" ]] || die "Bundle role=$EXPECTED does not match --role $ROLE"
  IRAN_IP="$(bget IRAN_IP "$BUNDLE")"
  FOREIGN_IP="$(bget FOREIGN_IP "$BUNDLE")"
  DOMAIN="$(bget DOMAIN "$BUNDLE")"
  WSS_TOKEN="$(bget WSS_TOKEN "$BUNDLE")"
  MUX_TOKEN="$(bget MUX_TOKEN "$BUNDLE")"
  TCP_TOKEN="$(bget TCP_TOKEN "$BUNDLE")"
  MUX_PORT="$(bget MUX_PORT "$BUNDLE")"
  TCP_PORT="$(bget TCP_PORT "$BUNDLE")"
  valid_ipv4 "$IRAN_IP" || die "Invalid IRAN_IP in bundle"
  valid_ipv4 "$FOREIGN_IP" || die "Invalid FOREIGN_IP in bundle"
  valid_domain "$DOMAIN" || die "Invalid DOMAIN in bundle"
  valid_token "$WSS_TOKEN" || die "Invalid WSS_TOKEN"
  valid_token "$MUX_TOKEN" || die "Invalid MUX_TOKEN"
  valid_token "$TCP_TOKEN" || die "Invalid TCP_TOKEN"

  write_health_service
  client_wss_cfg "$CFGDIR/client-wss.toml" "${DOMAIN}:443" "$WSS_TOKEN"
  client_mux_cfg "$CFGDIR/client-mux.toml" "${IRAN_IP}:${MUX_PORT}" "$MUX_TOKEN"
  client_tcp_cfg "$CFGDIR/client-tcp.toml" "${IRAN_IP}:${TCP_PORT}" "$TCP_TOKEN"
  chmod 0600 "$CFGDIR"/*.toml
  unit dual-bh-wss 'Dual Backhaul WSSMux client' "$CFGDIR/client-wss.toml"
  unit dual-bh-mux 'Dual Backhaul TCPMux client' "$CFGDIR/client-mux.toml"
  unit dual-bh-tcp 'Dual Backhaul plain TCP client' "$CFGDIR/client-tcp.toml"

  printf '%s\n' "$ROLE" > "$STATEDIR/role"
  cp -a "$BUNDLE" "$STATEDIR/bundle.env"
  chmod 0600 "$STATEDIR/bundle.env"

  systemctl daemon-reload
  systemctl enable --now dual-bh-health dual-bh-wss dual-bh-mux dual-bh-tcp >/dev/null
  write_diag

  echo
  log "$ROLE installed."
  if ss -lntp 2>/dev/null | grep -q '127\.0\.0\.1:443'; then
    log "Xray listener 127.0.0.1:443 detected."
  else
    warn "Xray is NOT listening on 127.0.0.1:443; tunnel health may work but users will not."
  fi
  info "Run: dual-diagnose"
fi

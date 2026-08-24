#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH=agent/dual-wss-stealth
REPO=aliiitavazoeiii-afk/backhaul-ha-installer
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}/dual-wss-stealth"
STATE=/etc/dual-wss-stealth
CFG=/etc/dual-wss-stealth
BIN=/usr/local/bin/backhaul-stealth
ROLE=""
BUNDLE=""
IRAN_IP=""
DOMAIN_A=""
DOMAIN_B=""
SKIP_DNS_CHECK=0

log(){ printf '[+] %s\n' "$*"; }
info(){ printf '[i] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --bundle) BUNDLE="${2:-}"; shift 2;;
    --iran-ip) IRAN_IP="${2:-}"; shift 2;;
    --domain-a) DOMAIN_A="${2:-}"; shift 2;;
    --domain-b) DOMAIN_B="${2:-}"; shift 2;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift;;
    -h|--help)
      cat <<'EOF'
Dual WSS Stealth installer

Iran:
  bash install.sh --role iran --iran-ip IRAN_IP --domain-a DOMAIN_A --domain-b DOMAIN_B

Foreign A/B:
  bash install.sh --role foreign --bundle /root/dual-stealth-a.env
  bash install.sh --role foreign --bundle /root/dual-stealth-b.env
EOF
      exit 0;;
    *) die "Unknown option: $1";;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run as root.'
source /etc/os-release 2>/dev/null || die 'Cannot detect OS.'
case "${ID:-}" in ubuntu|debian) ;; *) die 'Ubuntu/Debian only.';; esac
case "$(uname -m)" in x86_64|amd64) ;; *) die 'amd64 only.';; esac

valid_ipv4(){
  local ip="$1" IFS=. a o
  read -r -a a <<< "$ip"
  [[ ${#a[@]} -eq 4 ]] || return 1
  for o in "${a[@]}"; do [[ "$o" =~ ^[0-9]{1,3}$ ]] && ((10#$o<=255)) || return 1; done
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_token(){ [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]; }
valid_path(){ [[ "$1" =~ ^/[A-Za-z0-9/_-]{16,160}$ ]]; }
bget(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$2" | head -n1; }

prompt(){
  local var="$1" text="$2" v="${!1:-}"
  [[ -n "$v" ]] || { read -r -p "$text: " v; printf -v "$var" '%s' "$v"; }
}

install_common(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates tar python3 openssl
}

build_binary(){
  if [[ -x "$BIN" ]] && grep -aFq 'ws_control_path' "$BIN" && grep -aFq 'tls_skip_verify' "$BIN"; then
    log 'Custom-v2 stealth binary already present.'
    return
  fi
  local t
  t="$(mktemp)"
  curl -fsSL --retry 4 --retry-delay 2 "$RAW/build-custom-v2.sh" -o "$t"
  bash -n "$t"
  bash "$t"
  rm -f "$t"
}

write_unit(){
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

ensure_cert(){
  local domain="$1"
  [[ -s "/etc/letsencrypt/live/${domain}/fullchain.pem" && -s "/etc/letsencrypt/live/${domain}/privkey.pem" ]] && { log "Existing certificate: $domain"; return; }
  if (( SKIP_DNS_CHECK == 0 )); then
    local r
    r="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ "$r" == "$IRAN_IP" ]] || die "$domain resolves to ${r:-nothing}; expected $IRAN_IP"
  fi
  systemctl stop haproxy nginx >/dev/null 2>&1 || true
  if ss -lntp 2>/dev/null | grep -qE '(^|:)80[[:space:]]'; then
    die "Port 80 is occupied; cannot request certificate for $domain"
  fi
  certbot certonly --standalone -d "$domain" --agree-tos --register-unsafely-without-email --non-interactive
}

write_stealthctl_iran(){
cat > /usr/local/bin/stealthctl <<'CTL'
#!/usr/bin/env bash
set -u
CFG=/etc/haproxy/haproxy.cfg
cmd="${1:-status}"
case "$cmd" in
 status)
   echo '=== Dual WSS Stealth ==='
   systemctl is-active dual-stealth-a-server dual-stealth-b-server dual-stealth-tls nginx haproxy || true
   for p in 10444 20444; do
     printf '%s: ' "$p"
     curl -sS -o /dev/null --max-time 3 -w '%{http_code}\n' "http://127.0.0.1:${p}/healthz" 2>/dev/null || echo 000
   done
   grep -E 'server foreign_[ab] ' "$CFG" 2>/dev/null || true
   ;;
 diagnose)
   "$0" status
   echo
   journalctl -u dual-stealth-a-server -u dual-stealth-b-server -u haproxy -n 60 --no-pager
   ;;
 drain-a|drain-b)
   s="${cmd#drain-}"
   python3 - "$CFG" "$s" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); slot=sys.argv[2]
s=p.read_text(); name='foreign_a' if slot=='a' else 'foreign_b'
lines=[]
for line in s.splitlines():
    if re.match(rf'\s*server {name}\s+',line) and not re.search(r'\sdisabled\s*$',line): line += ' disabled'
    lines.append(line)
p.write_text('\n'.join(lines)+'\n')
PY
   haproxy -c -f "$CFG" && systemctl reload haproxy
   ;;
 activate-a|activate-b)
   s="${cmd#activate-}"
   python3 - "$CFG" "$s" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); slot=sys.argv[2]
s=p.read_text(); name='foreign_a' if slot=='a' else 'foreign_b'
lines=[]
for line in s.splitlines():
    if re.match(rf'\s*server {name}\s+',line): line=re.sub(r'\s+disabled\s*$','',line)
    lines.append(line)
p.write_text('\n'.join(lines)+'\n')
PY
   haproxy -c -f "$CFG" && systemctl reload haproxy
   ;;
 restart)
   systemctl restart dual-stealth-a-server dual-stealth-b-server dual-stealth-tls nginx haproxy
   ;;
 logs)
   journalctl -u dual-stealth-a-server -u dual-stealth-b-server -u dual-stealth-tls -u nginx -u haproxy -n 150 --no-pager
   ;;
 *) echo 'Usage: stealthctl {status|diagnose|drain-a|drain-b|activate-a|activate-b|restart|logs}'; exit 2;;
esac
CTL
chmod 0755 /usr/local/bin/stealthctl
}

write_stealthctl_foreign(){
cat > /usr/local/bin/stealthctl <<'CTL'
#!/usr/bin/env bash
set -u
cmd="${1:-status}"
case "$cmd" in
 status)
   echo "Slot: $(cat /etc/dual-wss-stealth/slot 2>/dev/null || echo '?')"
   echo "Domain: $(cat /etc/dual-wss-stealth/domain 2>/dev/null || echo '?')"
   systemctl is-active dual-stealth-client dual-stealth-health || true
   printf 'Local health: '; curl -sS -o /dev/null --max-time 2 -w '%{http_code}\n' http://127.0.0.1:18090/healthz 2>/dev/null || echo 000
   ss -lntp 2>/dev/null | grep '127.0.0.1:443' || true
   ;;
 restart) systemctl restart dual-stealth-health dual-stealth-client;;
 logs) journalctl -u dual-stealth-client -u dual-stealth-health -n 120 --no-pager;;
 *) echo 'Usage: stealthctl {status|restart|logs}'; exit 2;;
esac
CTL
chmod 0755 /usr/local/bin/stealthctl
}

install_iran(){
  prompt IRAN_IP 'Iran public IPv4'
  prompt DOMAIN_A 'Foreign A WSS Stealth domain (points to Iran)'
  prompt DOMAIN_B 'Foreign B WSS Stealth domain (points to Iran)'
  valid_ipv4 "$IRAN_IP" || die 'Invalid Iran IPv4.'
  valid_domain "$DOMAIN_A" || die 'Invalid Domain A.'
  valid_domain "$DOMAIN_B" || die 'Invalid Domain B.'
  [[ "$DOMAIN_A" != "$DOMAIN_B" ]] || die 'Domain A and B must differ.'

  install_common
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y haproxy nginx stunnel4 certbot ufw
  rm -f /etc/nginx/sites-enabled/default
  systemctl stop nginx haproxy >/dev/null 2>&1 || true
  build_binary
  ensure_cert "$DOMAIN_A"
  ensure_cert "$DOMAIN_B"

  install -d -m 0700 "$CFG" /var/www/dual-stealth-decoy /etc/stunnel /etc/letsencrypt/renewal-hooks/deploy
  printf '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1><p>The service is online.</p></body></html>\n' > /var/www/dual-stealth-decoy/index.html

  local ta tb ca cb pa pb
  ta="$(openssl rand -hex 32)"; tb="$(openssl rand -hex 32)"
  ca="/assets/v3/$(openssl rand -hex 16)"; cb="/assets/v3/$(openssl rand -hex 16)"
  pa="/api/socket/$(openssl rand -hex 16)"; pb="/api/socket/$(openssl rand -hex 16)"

  cat > "$CFG/a-server.toml" <<EOF
[server]
bind_addr = "127.0.0.1:18080"
transport = "wsmux"
token = "$ta"
keepalive_period = 75
heartbeat = 40
nodelay = true
channel_size = 2048
mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
ws_control_path = "$ca"
ws_tunnel_path = "$pa"
sniffer = false
web_port = 0
log_level = "info"
ports = [
  "10443=127.0.0.1:443",
  "10444=127.0.0.1:18090"
]
EOF
  cat > "$CFG/b-server.toml" <<EOF
[server]
bind_addr = "127.0.0.1:28080"
transport = "wsmux"
token = "$tb"
keepalive_period = 75
heartbeat = 40
nodelay = true
channel_size = 2048
mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
ws_control_path = "$cb"
ws_tunnel_path = "$pb"
sniffer = false
web_port = 0
log_level = "info"
ports = [
  "20443=127.0.0.1:443",
  "20444=127.0.0.1:18090"
]
EOF
  chmod 0600 "$CFG"/*.toml
  write_unit dual-stealth-a-server 'Dual Stealth Foreign-A WSMux server' "$CFG/a-server.toml"
  write_unit dual-stealth-b-server 'Dual Stealth Foreign-B WSMux server' "$CFG/b-server.toml"

  cat > /etc/nginx/sites-available/dual-wss-stealth <<EOF
server {
    listen 127.0.0.1:9080;
    server_name $DOMAIN_A;
    server_tokens off;
    root /var/www/dual-stealth-decoy;
    index index.html;
    access_log off;
    location = $ca {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header X-User-Id \$http_x_user_id;
        proxy_read_timeout 1d; proxy_send_timeout 1d;
        proxy_buffering off; proxy_request_buffering off; proxy_socket_keepalive on;
        proxy_pass http://127.0.0.1:18080;
    }
    location ^~ $pa/ {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header X-User-Id \$http_x_user_id;
        proxy_read_timeout 1d; proxy_send_timeout 1d;
        proxy_buffering off; proxy_request_buffering off; proxy_socket_keepalive on;
        proxy_pass http://127.0.0.1:18080;
    }
    location / { try_files \$uri \$uri/ =404; }
}
server {
    listen 127.0.0.1:9081;
    server_name $DOMAIN_B;
    server_tokens off;
    root /var/www/dual-stealth-decoy;
    index index.html;
    access_log off;
    location = $cb {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header X-User-Id \$http_x_user_id;
        proxy_read_timeout 1d; proxy_send_timeout 1d;
        proxy_buffering off; proxy_request_buffering off; proxy_socket_keepalive on;
        proxy_pass http://127.0.0.1:28080;
    }
    location ^~ $pb/ {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header X-User-Id \$http_x_user_id;
        proxy_read_timeout 1d; proxy_send_timeout 1d;
        proxy_buffering off; proxy_request_buffering off; proxy_socket_keepalive on;
        proxy_pass http://127.0.0.1:28080;
    }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  ln -sfn /etc/nginx/sites-available/dual-wss-stealth /etc/nginx/sites-enabled/dual-wss-stealth
  nginx -t

  local stunnel_bin
  stunnel_bin="$(command -v stunnel4 || command -v stunnel || true)"
  [[ -n "$stunnel_bin" ]] || die 'stunnel binary not found.'
  cat > "$CFG/stunnel.conf" <<EOF
foreground = yes
syslog = no
debug = notice
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[foreign-a]
accept = 127.0.0.1:9443
connect = 127.0.0.1:9080
cert = /etc/letsencrypt/live/$DOMAIN_A/fullchain.pem
key = /etc/letsencrypt/live/$DOMAIN_A/privkey.pem
sslVersionMin = TLSv1.2
TIMEOUTconnect = 10
TIMEOUTclose = 5
TIMEOUTidle = 43200

[foreign-b]
accept = 127.0.0.1:9444
connect = 127.0.0.1:9081
cert = /etc/letsencrypt/live/$DOMAIN_B/fullchain.pem
key = /etc/letsencrypt/live/$DOMAIN_B/privkey.pem
sslVersionMin = TLSv1.2
TIMEOUTconnect = 10
TIMEOUTclose = 5
TIMEOUTidle = 43200
EOF
  chmod 0600 "$CFG/stunnel.conf"
  cat > /etc/systemd/system/dual-stealth-tls.service <<EOF
[Unit]
Description=Dual WSS Stealth TLS terminators
After=network-online.target nginx.service
Wants=network-online.target
Requires=nginx.service

[Service]
Type=simple
ExecStart=$stunnel_bin $CFG/stunnel.conf
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/letsencrypt/renewal-hooks/deploy/dual-wss-stealth <<'EOF'
#!/usr/bin/env bash
systemctl restart dual-stealth-tls.service >/dev/null 2>&1 || true
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/dual-wss-stealth

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
    timeout check 4s

frontend public_https
    bind *:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    acl control_a req.ssl_sni -i $DOMAIN_A
    acl control_b req.ssl_sni -i $DOMAIN_B
    use_backend stealth_control_a if control_a
    use_backend stealth_control_b if control_b
    default_backend vpn_users

backend stealth_control_a
    mode tcp
    server a_tls 127.0.0.1:9443
backend stealth_control_b
    mode tcp
    server b_tls 127.0.0.1:9444

backend vpn_users
    mode tcp
    balance roundrobin
    stick-table type ip size 1m expire 1h
    stick on src
    option redispatch
    retries 2
    option httpchk GET /healthz
    http-check expect status 200
    server foreign_a 127.0.0.1:10443 check port 10444 inter 2s fall 3 rise 5 on-marked-down shutdown-sessions
    server foreign_b 127.0.0.1:20443 check port 20444 inter 2s fall 3 rise 5 on-marked-down shutdown-sessions
EOF
  haproxy -c -f /etc/haproxy/haproxy.cfg

  cat > /root/dual-stealth-a.env <<EOF
SLOT='a'
IRAN_IP='$IRAN_IP'
DOMAIN='$DOMAIN_A'
TOKEN='$ta'
CONTROL_PATH='$ca'
TUNNEL_PATH='$pa'
EOF
  cat > /root/dual-stealth-b.env <<EOF
SLOT='b'
IRAN_IP='$IRAN_IP'
DOMAIN='$DOMAIN_B'
TOKEN='$tb'
CONTROL_PATH='$cb'
TUNNEL_PATH='$pb'
EOF
  chmod 0600 /root/dual-stealth-a.env /root/dual-stealth-b.env
  printf 'iran\n' > "$STATE/role"
  printf '%s\n' "$DOMAIN_A" > "$STATE/domain-a"
  printf '%s\n' "$DOMAIN_B" > "$STATE/domain-b"

  ufw allow 80/tcp comment 'Dual Stealth certbot' >/dev/null 2>&1 || true
  ufw allow 443/tcp comment 'Dual Stealth public HTTPS' >/dev/null 2>&1 || true

  systemctl daemon-reload
  systemctl enable dual-stealth-a-server dual-stealth-b-server dual-stealth-tls nginx haproxy >/dev/null
  systemctl restart dual-stealth-a-server dual-stealth-b-server nginx dual-stealth-tls haproxy
  write_stealthctl_iran

  sleep 2
  log 'Iran installed. Both slots will stay HAProxy-DOWN until their Foreign clients connect and health succeeds.'
  echo "[NEXT A] scp /root/dual-stealth-a.env root@FOREIGN_A_IP:/root/dual-stealth-a.env"
  echo "[NEXT B] scp /root/dual-stealth-b.env root@FOREIGN_B_IP:/root/dual-stealth-b.env"
  echo "Then on each Foreign run this installer with --role foreign --bundle <its bundle>."
  stealthctl status || true
}

install_foreign(){
  [[ -n "$BUNDLE" ]] || BUNDLE=/root/dual-stealth.env
  [[ -f "$BUNDLE" ]] || die "Bundle not found: $BUNDLE"
  chmod 0600 "$BUNDLE"
  local slot domain token ctrl tun iran
  slot="$(bget SLOT "$BUNDLE")"; iran="$(bget IRAN_IP "$BUNDLE")"; domain="$(bget DOMAIN "$BUNDLE")"
  token="$(bget TOKEN "$BUNDLE")"; ctrl="$(bget CONTROL_PATH "$BUNDLE")"; tun="$(bget TUNNEL_PATH "$BUNDLE")"
  [[ "$slot" == a || "$slot" == b ]] || die 'Invalid slot in bundle.'
  valid_ipv4 "$iran" || die 'Invalid Iran IP in bundle.'
  valid_domain "$domain" || die 'Invalid domain in bundle.'
  valid_token "$token" || die 'Invalid token in bundle.'
  valid_path "$ctrl" || die 'Invalid control path.'
  valid_path "$tun" || die 'Invalid tunnel path.'

  install_common
  build_binary
  install -d -m 0700 "$CFG" /opt/dual-stealth-health

  cat > "$CFG/client.toml" <<EOF
[client]
remote_addr = "$domain:443"
edge_ip = ""
transport = "wssmux"
token = "$token"
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
ws_control_path = "$ctrl"
ws_tunnel_path = "$tun"
tls_server_name = "$domain"
tls_skip_verify = false
ws_origin = "https://$domain"
sniffer = false
web_port = 0
log_level = "info"
EOF
  chmod 0600 "$CFG/client.toml"
  write_unit dual-stealth-client "Dual WSS Stealth Foreign-$slot client" "$CFG/client.toml"

  cat > /opt/dual-stealth-health/server.py <<'PY'
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class S(ThreadingHTTPServer):
    request_queue_size=128
    daemon_threads=True
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/healthz': self.send_response(404); self.end_headers(); return
        try:
            with socket.create_connection(('127.0.0.1',443),timeout=.7): ok=True
        except OSError: ok=False
        body=b'XRAY_OK\n' if ok else b'XRAY_DOWN\n'
        self.send_response(200 if ok else 503)
        self.send_header('Content-Length',str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except Exception: pass
    def log_message(self,*_): pass
S(('127.0.0.1',18090),H).serve_forever()
PY
  cat > /etc/systemd/system/dual-stealth-health.service <<'EOF'
[Unit]
Description=Dual WSS Stealth Xray-aware health
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/dual-stealth-health/server.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  printf 'foreign\n' > "$STATE/role"
  printf '%s\n' "$slot" > "$STATE/slot"
  printf '%s\n' "$domain" > "$STATE/domain"

  root_code="$(curl -ksS --max-time 8 -o /dev/null -w '%{http_code}' "https://${domain}/" 2>/dev/null || true)"
  [[ "$root_code" == 200 ]] || warn "Decoy root currently returns ${root_code:-error}; client will still be started for diagnostics."

  systemctl daemon-reload
  systemctl enable dual-stealth-health dual-stealth-client >/dev/null
  systemctl restart dual-stealth-health dual-stealth-client
  write_stealthctl_foreign
  sleep 3
  log "Foreign-$slot installed."
  stealthctl status || true
}

if [[ -z "$ROLE" ]]; then
  echo '1) Iran controller'
  echo '2) Foreign A/B'
  read -r -p 'Select role [1/2]: ' r
  [[ "$r" == 1 ]] && ROLE=iran || ROLE=foreign
fi

case "$ROLE" in
  iran) install_iran;;
  foreign) install_foreign;;
  *) die '--role must be iran or foreign';;
esac

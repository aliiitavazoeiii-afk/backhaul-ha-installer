#!/usr/bin/env bash
set -Eeuo pipefail

FRP_VERSION="0.70.1"
FRP_DIR="/opt/frp-nomux"
CFG_DIR="/etc/frp-nomux"
LOG_DIR="/var/log/frp-nomux"
TOKEN_FILE="$CFG_DIR/token"
BUNDLE_OUT="/root/frp-nomux.env"
NGINX_CONF="/etc/nginx/conf.d/aegis-single.conf"
NGINX_SNIPPET="/etc/nginx/snippets/frp-nomux.conf"
HAPROXY_CONF="/etc/haproxy/haproxy.cfg"
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
  bash install.sh --role iran --iran-ip 94.184.4.38 --domain ag2.biya2film.top
FOREIGN:
  bash install.sh --role foreign --bundle /root/frp-nomux.env
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

valid_ip(){
  python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1])
except Exception: raise SystemExit(1)
PY
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }

install_deps(){
  local miss=0
  for c in curl tar sha256sum openssl python3 ss; do command -v "$c" >/dev/null || miss=1; done
  if ((miss)); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates tar openssl python3 iproute2
  fi
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

backup_dir(){ local d="/root/frp-nomux-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$d"; echo "$d"; }

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
healthCheck.maxFailed = 3
healthCheck.intervalSeconds = 3
EOF
  chmod 0600 "$CFG_DIR/frpc.toml"
}

write_unit(){
  local side="$1" bin="$2" cfg="$3"
  cat >"/etc/systemd/system/${side}-nomux.service" <<EOF
[Unit]
Description=FRP WSS no-mux ${side}
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

patch_nginx(){
  local bak="$1"
  mkdir -p /etc/nginx/snippets
  cat >"$NGINX_SNIPPET" <<'EOF'
location = /~!frp {
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 1d;
    proxy_send_timeout 1d;
    proxy_pass http://127.0.0.1:18081;
}
EOF
  if ! grep -Fq "include $NGINX_SNIPPET;" "$NGINX_CONF"; then
    python3 - "$NGINX_CONF" "$DOMAIN" "$NGINX_SNIPPET" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]); domain=sys.argv[2]; snippet=sys.argv[3]
s=p.read_text(); n=f"    server_name {domain};\n"
if n not in s: raise SystemExit("matching server_name not found")
p.write_text(s.replace(n,n+f"    include {snippet};\n",1))
PY
  fi
  if ! nginx -t; then
    cp -a "$bak/aegis-single.conf" "$NGINX_CONF"
    rm -f "$NGINX_SNIPPET"
    die "nginx validation failed; restored"
  fi
}

strip_test(){
  python3 - "$HAPROXY_CONF" <<'PY'
import re,sys
from pathlib import Path
p=Path(sys.argv[1]); s=p.read_text()
s=re.sub(r'\n?# BEGIN FRP_NOMUX_TEST\n.*?# END FRP_NOMUX_TEST\n?', '\n', s, flags=re.S)
p.write_text(s.rstrip()+"\n")
PY
}

patch_test(){
  local bak="$1"
  strip_test
  cat >>"$HAPROXY_CONF" <<EOF

# BEGIN FRP_NOMUX_TEST
frontend frp_nomux_test_$TEST_PORT
    bind *:$TEST_PORT
    mode tcp
    default_backend frp_nomux_gateway
backend frp_nomux_gateway
    mode tcp
    option redispatch
    retries 2
    server frp_nomux 127.0.0.1:$PROXY_PORT check inter 1s fall 2 rise 2
# END FRP_NOMUX_TEST
EOF
  haproxy -c -f "$HAPROXY_CONF" || { cp -a "$bak/haproxy.cfg" "$HAPROXY_CONF"; die "HAProxy validation failed; restored"; }
}

save_aegis_line(){
  [[ -s "$CFG_DIR/aegis-backend-line" ]] && return
  python3 - "$HAPROXY_CONF" "$CFG_DIR/aegis-backend-line" <<'PY'
import re,sys
from pathlib import Path
lines=Path(sys.argv[1]).read_text().splitlines(); inside=False
for x in lines:
    if re.match(r'^backend\s+user_gateway\s*$',x): inside=True; continue
    if inside and re.match(r'^(backend|frontend|listen|global|defaults)\b',x): break
    if inside and re.match(r'^\s*server\s+',x): Path(sys.argv[2]).write_text(x.strip()+"\n"); break
else: raise SystemExit("user_gateway server line not found")
PY
  chmod 0600 "$CFG_DIR/aegis-backend-line"
}

write_frpctl(){
  cat >/usr/local/bin/frpctl <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
H=/etc/haproxy/haproxy.cfg; D=/etc/frp-nomux; P=10445; T=2443
replace(){
  python3 - "$H" "$1" <<'PY'
import re,sys
from pathlib import Path
p=Path(sys.argv[1]); new=sys.argv[2]; lines=p.read_text().splitlines(); out=[]; inside=False; done=False
for x in lines:
    if re.match(r'^backend\s+user_gateway\s*$',x): inside=True; out.append(x); continue
    if inside and re.match(r'^(backend|frontend|listen|global|defaults)\b',x):
        if not done: out.append('    '+new); done=True
        inside=False
    if inside and re.match(r'^\s*server\s+',x):
        if not done: out.append('    '+new); done=True
        continue
    out.append(x)
if inside and not done: out.append('    '+new); done=True
if not done: raise SystemExit('backend user_gateway not found')
p.write_text('\n'.join(out)+'\n')
PY
}
reload_safe(){ local b="$1"; haproxy -c -f "$H" || { cp -a "$b" "$H"; echo '[x] invalid HAProxy config; restored' >&2; exit 1; }; systemctl reload haproxy; }
case "${1:-status}" in
 status)
  echo '=== FRPS ==='; systemctl is-active frps-nomux || true
  echo '=== FRP PROXY ==='; ss -Hlnpt | grep -q "127.0.0.1:$P " && echo UP || echo DOWN
  echo '=== USER BACKEND ==='; awk '/^backend user_gateway$/{p=1;next} p&&/^(backend|frontend|listen|global|defaults)[[:space:]]/{exit} p&&/^[[:space:]]*server[[:space:]]/{print}' "$H"
  echo '=== TEST PORT ==='; ss -lnt | grep ":$T " || true;;
 cutover)
  ss -Hlnpt | grep -q "127.0.0.1:$P " || { echo '[x] FRP proxy DOWN; refusing cutover' >&2; exit 1; }
  b="$D/haproxy-before-cutover-$(date +%Y%m%d-%H%M%S).cfg"; cp -a "$H" "$b"
  replace "server frp_nomux 127.0.0.1:$P check inter 1s fall 2 rise 2"; reload_safe "$b"
  echo '[+] New connections use FRP; existing Aegis connections drain gracefully.';;
 rollback)
  [[ -s "$D/aegis-backend-line" ]] || { echo '[x] saved Aegis backend missing' >&2; exit 1; }
  b="$D/haproxy-before-rollback-$(date +%Y%m%d-%H%M%S).cfg"; cp -a "$H" "$b"
  replace "$(cat "$D/aegis-backend-line")"; reload_safe "$b"
  echo '[+] New connections use Aegis again; existing FRP connections drain gracefully.';;
 test-off)
  b="$D/haproxy-before-test-off-$(date +%Y%m%d-%H%M%S).cfg"; cp -a "$H" "$b"
  python3 - "$H" <<'PY'
import re,sys
from pathlib import Path
p=Path(sys.argv[1]); s=p.read_text(); s=re.sub(r'\n?# BEGIN FRP_NOMUX_TEST\n.*?# END FRP_NOMUX_TEST\n?','\n',s,flags=re.S); p.write_text(s.rstrip()+"\n")
PY
  reload_safe "$b"
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active' && ufw --force delete allow 2443/tcp >/dev/null 2>&1 || true
  echo '[+] test port removed';;
 logs) journalctl -u frps-nomux -n 100 --no-pager;;
 *) echo 'Usage: frpctl {status|cutover|rollback|test-off|logs}' >&2; exit 2;;
esac
EOF
  chmod 0755 /usr/local/bin/frpctl
}

install_iran(){
  valid_ip "$IRAN_IP" || die "invalid --iran-ip"
  valid_domain "$DOMAIN" || die "invalid --domain"
  [[ -f "$NGINX_CONF" && -f "$HAPROXY_CONF" ]] || die "current Aegis Nginx/HAProxy config not found"
  systemctl is-active --quiet nginx || die "nginx not active"
  systemctl is-active --quiet haproxy || die "haproxy not active"
  grep -Fq "server_name $DOMAIN;" "$NGINX_CONF" || die "$DOMAIN is not the current Aegis carrier domain"

  install_deps; install_frp
  [[ -s "$TOKEN_FILE" ]] || { umask 077; openssl rand -hex 32 >"$TOKEN_FILE"; }
  chmod 0600 "$TOKEN_FILE"
  write_frps; write_unit frps frps frps.toml

  local bak; bak="$(backup_dir)"
  cp -a "$NGINX_CONF" "$bak/aegis-single.conf"; cp -a "$HAPROXY_CONF" "$bak/haproxy.cfg"
  save_aegis_line; patch_nginx "$bak"; patch_test "$bak"

  systemctl daemon-reload
  systemctl enable --now frps-nomux >/dev/null
  sleep 1
  systemctl is-active --quiet frps-nomux || { journalctl -u frps-nomux -n 80 --no-pager || true; die "frps-nomux failed"; }
  systemctl reload nginx; systemctl reload haproxy
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active' && ufw allow "$TEST_PORT/tcp" >/dev/null || true

  local tok; tok="$(cat "$TOKEN_FILE")"; umask 077
  cat >"$BUNDLE_OUT" <<EOF
ROLE='foreign'
IRAN_IP='$IRAN_IP'
DOMAIN='$DOMAIN'
TOKEN='$tok'
FRP_VERSION='$FRP_VERSION'
PROXY_PORT='$PROXY_PORT'
POOL_COUNT='$POOL_COUNT'
EOF
  chmod 0600 "$BUNDLE_OUT"; write_frpctl
  log "Iran FRP WSS no-mux installed in parallel; Aegis production path unchanged"
  echo "[+] Bundle: $BUNDLE_OUT"
  echo "[+] Public test port: $TEST_PORT -> FRP"
  echo "[i] Do NOT cut over yet. Install Foreign, then test port $TEST_PORT."
  frpctl status || true
}

bget(){ grep -E "^$1='" "$BUNDLE" | head -1 | cut -d"'" -f2; }
install_foreign(){
  [[ -f "$BUNDLE" ]] || die "--bundle file required"
  local br tok bv bp pc
  br="$(bget ROLE)"; IRAN_IP="$(bget IRAN_IP)"; DOMAIN="$(bget DOMAIN)"; tok="$(bget TOKEN)"; bv="$(bget FRP_VERSION)"; bp="$(bget PROXY_PORT)"; pc="$(bget POOL_COUNT)"
  [[ "$br" == foreign && "$bv" == "$FRP_VERSION" && "$bp" == "$PROXY_PORT" && "$pc" == "$POOL_COUNT" ]] || die "invalid/incompatible bundle"
  valid_ip "$IRAN_IP" || die "invalid Iran IP in bundle"; valid_domain "$DOMAIN" || die "invalid domain in bundle"; [[ "$tok" =~ ^[0-9a-f]{64}$ ]] || die "invalid token"
  timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null || die "Xray is not listening on 127.0.0.1:443; nothing changed"

  install_deps; install_frp
  printf '%s\n' "$tok" >"$TOKEN_FILE"; chmod 0600 "$TOKEN_FILE"
  write_frpc; write_unit frpc frpc frpc.toml
  systemctl daemon-reload; systemctl enable --now frpc-nomux >/dev/null
  sleep 3
  systemctl is-active --quiet frpc-nomux || { journalctl -u frpc-nomux -n 100 --no-pager || true; die "frpc-nomux failed"; }

  local ok=0
  for _ in {1..15}; do
    ss -Hntp state established dst "$IRAN_IP:443" 2>/dev/null | grep -q 'frpc' && { ok=1; break; }
    sleep 1
  done
  ((ok)) || { journalctl -u frpc-nomux -n 100 --no-pager || true; die "frpc active but no WSS connection to Iran:443"; }
  log "Foreign FRP WSS no-mux installed; Xray preserved"
  echo '=== FRPC ==='; systemctl is-active frpc-nomux
  echo '=== XRAY LOCAL ==='; timeout 2 bash -c '</dev/tcp/127.0.0.1/443' && echo UP || echo DOWN
  echo '=== WSS CONNECTIONS ==='; ss -Hntp state established dst "$IRAN_IP:443" | grep 'frpc' | wc -l
}

[[ "$ROLE" == iran ]] && install_iran || install_foreign

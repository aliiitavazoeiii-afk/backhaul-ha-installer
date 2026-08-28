#!/usr/bin/env bash
set -Eeuo pipefail

# Parallel FRP sharded-mux deployment for an existing FRP no-mux production pair.
# Existing production remains on 127.0.0.1:10445. New sharded backend is 127.0.0.1:10447.
# Carrier ingress for shards is TLS/WSS on public :8443. User test ingress is public :2444.
# Cutover only changes HAProxy backend with a graceful reload; old sessions are left to drain.

BIN_DIR="/opt/frp-nomux/bin"
BASE_DIR="/etc/frp-nomux"
SHARD_DIR="/etc/frp-sharded"
LOG_DIR="/var/log/frp-sharded"
OLD_PROXY_PORT=10445
NEW_FRPS_PORT=18083
NEW_PROXY_PORT=10447
CARRIER_PORT=8443
TEST_PORT=2444
SHARDS=16
POOL_COUNT=4
MAX_POOL_COUNT=8
ROLE=""
IRAN_IP=""
DOMAIN=""
BUNDLE=""
BUNDLE_OUT="/root/frp-sharded-bundle.tar.gz"

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

usage(){ cat <<'EOF'
IRAN:
  bash install-sharded-live.sh --role iran --iran-ip 185.215.230.204 --domain aeg.biya2film.top
FOREIGN:
  bash install-sharded-live.sh --role foreign --bundle /root/frp-sharded-bundle.tar.gz
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

valid_ip(){ python3 - "$1" <<'PY'
import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1])
except Exception: raise SystemExit(1)
PY
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
port_busy(){ ss -Hlnpt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$1$"; }

require_base(){
  [[ -x "$BIN_DIR/frps" && -x "$BIN_DIR/frpc" ]] || die "existing FRP binaries not found in $BIN_DIR"
}

maybe_open_ufw(){
  command -v ufw >/dev/null || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw allow "$CARRIER_PORT/tcp" >/dev/null
  ufw allow "$TEST_PORT/tcp" >/dev/null
}

write_frps(){
  install -d -m 0700 "$SHARD_DIR" "$LOG_DIR"
  [[ -s "$SHARD_DIR/token" ]] || { umask 077; openssl rand -hex 32 >"$SHARD_DIR/token"; }
  [[ -s "$SHARD_DIR/group.key" ]] || { umask 077; openssl rand -hex 32 >"$SHARD_DIR/group.key"; }
  chmod 0600 "$SHARD_DIR/token" "$SHARD_DIR/group.key"
  cat >"$SHARD_DIR/frps.toml" <<EOF
bindAddr = "127.0.0.1"
bindPort = $NEW_FRPS_PORT
proxyBindAddr = "127.0.0.1"
transport.maxPoolCount = $MAX_POOL_COUNT
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 20
transport.tcpKeepalive = 30
transport.tls.force = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$SHARD_DIR/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

allowPorts = [{ single = $NEW_PROXY_PORT }]
maxPortsPerClient = 1
userConnTimeout = 5

log.to = "$LOG_DIR/frps.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true
EOF
  chmod 0600 "$SHARD_DIR/frps.toml"

  cat >/etc/systemd/system/frps-sharded.service <<EOF
[Unit]
Description=FRP 16-shard mux server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/frps -c $SHARD_DIR/frps.toml
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

write_nginx(){
  cat >/etc/nginx/conf.d/frp-sharded.conf <<EOF
server {
    listen 0.0.0.0:$CARRIER_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:FRPSHARD:20m;
    ssl_session_timeout 1d;

    location = /~!frp {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_pass http://127.0.0.1:$NEW_FRPS_PORT;
    }

    location / { return 404; }
}
EOF
}

patch_haproxy_test(){
  local H=/etc/haproxy/haproxy.cfg
  [[ -s "$H" ]] || die "HAProxy config not found"
  cp -a "$H" "/root/haproxy.before-sharded.$(date +%Y%m%d-%H%M%S).cfg"
  grep -q '^backend frp_sharded_gateway$' "$H" || cat >>"$H" <<EOF

backend frp_sharded_gateway
    mode tcp
    option redispatch
    retries 2
    server frp_sharded 127.0.0.1:$NEW_PROXY_PORT check inter 1s fall 2 rise 2

frontend frp_sharded_test_$TEST_PORT
    bind *:$TEST_PORT
    mode tcp
    default_backend frp_sharded_gateway
EOF
}

write_ctl(){
  cat >/usr/local/bin/frp-shardctl <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
H=/etc/haproxy/haproxy.cfg
OLD=10445
NEW=10447
replace_backend(){
  local port="$1" name="$2"
  python3 - "$H" "$port" "$name" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); port=sys.argv[2]; name=sys.argv[3]
lines=p.read_text().splitlines(); out=[]; inside=False; done=False
for x in lines:
    if re.match(r'^backend\s+frp_user_gateway\s*$',x):
        inside=True; out.append(x); continue
    if inside and re.match(r'^(backend|frontend|listen|global|defaults)\b',x):
        inside=False
    if inside and re.match(r'^\s*server\s+',x):
        if not done:
            out.append(f'    server {name} 127.0.0.1:{port} check inter 1s fall 2 rise 2')
            done=True
        continue
    out.append(x)
if not done: raise SystemExit('frp_user_gateway server line not found')
p.write_text('\n'.join(out)+'\n')
PY
}
reload_haproxy(){
  local b="$1"
  haproxy -c -f "$H" >/dev/null || { cp -a "$b" "$H"; echo '[x] invalid config; restored' >&2; exit 1; }
  systemctl reload haproxy
}
count_to(){ ss -Htn state established dst 127.0.0.1:"$1" 2>/dev/null | wc -l; }
case "${1:-status}" in
 status)
   echo '=== SHARDED FRPS ==='; systemctl is-active frps-sharded || true
   echo '=== SHARDED USER PROXY ==='; ss -Hlnpt | grep -q '127.0.0.1:10447 ' && echo UP || echo DOWN
   echo '=== CURRENT PROD BACKEND ==='; awk '/^backend frp_user_gateway$/{p=1;next} p&&/^(backend|frontend|listen|global|defaults)/{exit} p&&/^[[:space:]]*server[[:space:]]/{print}' "$H"
   echo "legacy streams : $(count_to 10445)"
   echo "sharded streams: $(count_to 10447)"
   echo "carrier tcp sessions on :8443: $(ss -Htn state established sport = :8443 2>/dev/null | wc -l)"
   ;;
 cutover)
   ss -Hlnpt | grep -q '127.0.0.1:10447 ' || { echo '[x] sharded proxy DOWN; refusing cutover' >&2; exit 1; }
   timeout 3 bash -c '</dev/tcp/127.0.0.1/10447' 2>/dev/null || { echo '[x] sharded backend health probe failed' >&2; exit 1; }
   b="/root/haproxy.cutover.$(date +%Y%m%d-%H%M%S).cfg"; cp -a "$H" "$b"
   replace_backend 10447 frp_sharded
   reload_haproxy "$b"
   echo '[+] Graceful HAProxy reload done. New user connections go to sharded FRP.'
   echo '[i] Existing old user TCP sessions are left on the old HAProxy process to drain naturally.'
   ;;
 rollback)
   ss -Hlnpt | grep -q '127.0.0.1:10445 ' || { echo '[x] legacy proxy DOWN; refusing rollback' >&2; exit 1; }
   b="/root/haproxy.rollback.$(date +%Y%m%d-%H%M%S).cfg"; cp -a "$H" "$b"
   replace_backend 10445 frp_user
   reload_haproxy "$b"
   echo '[+] New connections use legacy no-mux FRP again. Existing sharded sessions are not deliberately killed.'
   ;;
 drain)
   echo "legacy established backend streams : $(count_to 10445)"
   echo "sharded established backend streams: $(count_to 10447)"
   ;;
 *) echo 'Usage: frp-shardctl {status|cutover|rollback|drain}' >&2; exit 2;;
esac
EOF
  chmod 0755 /usr/local/bin/frp-shardctl
}

make_bundle(){
  local tmp
  tmp="$(mktemp -d)"
  umask 077
  cat >"$tmp/env" <<EOF
IRAN_IP='$IRAN_IP'
DOMAIN='$DOMAIN'
TOKEN='$(cat "$SHARD_DIR/token")'
GROUP_KEY='$(cat "$SHARD_DIR/group.key")'
SHARDS='$SHARDS'
POOL_COUNT='$POOL_COUNT'
EOF
  tar -C "$tmp" -czf "$BUNDLE_OUT" env
  chmod 0600 "$BUNDLE_OUT"
  rm -rf "$tmp"
}

install_iran(){
  require_base
  [[ -n "$IRAN_IP" && -n "$DOMAIN" ]] || die "--iran-ip and --domain required"
  valid_ip "$IRAN_IP" || die "invalid Iran IP"
  valid_domain "$DOMAIN" || die "invalid domain"
  systemctl is-active --quiet haproxy || die "live HAProxy is not active"
  systemctl is-active --quiet nginx || die "live Nginx is not active"
  systemctl is-active --quiet frps-nomux || die "legacy frps-nomux is not active"
  [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || die "existing certificate for $DOMAIN not found"
  [[ -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]] || die "existing key for $DOMAIN not found"

  for p in "$NEW_FRPS_PORT" "$NEW_PROXY_PORT" "$CARRIER_PORT" "$TEST_PORT"; do
    if port_busy "$p"; then
      case "$p" in
        "$NEW_FRPS_PORT") systemctl is-active --quiet frps-sharded || die "port $p busy by unexpected service";;
        "$CARRIER_PORT") [[ -s /etc/nginx/conf.d/frp-sharded.conf ]] || die "port $p busy by unexpected service";;
        "$TEST_PORT") grep -q "frp_sharded_test_$TEST_PORT" /etc/haproxy/haproxy.cfg || die "port $p busy by unexpected service";;
        "$NEW_PROXY_PORT") :;;
      esac
    fi
  done

  mkdir -p "$LOG_DIR"
  write_frps
  write_nginx
  patch_haproxy_test
  write_ctl
  make_bundle
  maybe_open_ufw

  nginx -t
  haproxy -c -f /etc/haproxy/haproxy.cfg
  systemctl daemon-reload
  systemctl enable --now frps-sharded >/dev/null
  # Only graceful reloads: do not restart live Nginx/HAProxy.
  systemctl reload nginx
  systemctl reload haproxy

  sleep 2
  systemctl is-active --quiet frps-sharded || die "frps-sharded failed"
  log "Iran sharded layer installed in parallel; production backend was not changed"
  echo "[+] Foreign bundle: $BUNDLE_OUT"
  echo "[+] Carrier endpoint: $DOMAIN:$CARRIER_PORT"
  echo "[+] Test user endpoint: $IRAN_IP:$TEST_PORT"
  frp-shardctl status
}

load_bundle(){
  [[ -n "$BUNDLE" && -s "$BUNDLE" ]] || die "--bundle required"
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$BUNDLE" -C "$tmp" env
  # shellcheck disable=SC1090
  source "$tmp/env"
  rm -rf "$tmp"
  valid_ip "$IRAN_IP" || die "invalid bundle Iran IP"
  valid_domain "$DOMAIN" || die "invalid bundle domain"
  [[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] || die "invalid token"
  [[ "$GROUP_KEY" =~ ^[0-9a-f]{64}$ ]] || die "invalid group key"
  [[ "$SHARDS" =~ ^[0-9]+$ && "$SHARDS" -ge 2 && "$SHARDS" -le 32 ]] || die "invalid shard count"
}

write_foreign_ctl(){
  cat >/usr/local/bin/frp-shardctl <<EOF
#!/usr/bin/env bash
set -u
case "\${1:-status}" in
 status)
   active=0
   for i in \$(seq -w 1 $SHARDS); do systemctl is-active --quiet frpc-shard@\$i && active=\$((active+1)); done
   echo "active shard services: \$active/$SHARDS"
   echo -n 'Xray local: '; timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null && echo UP || echo DOWN
   echo -n 'TCP sessions to Iran:$CARRIER_PORT: '; ss -Htn state established dst $IRAN_IP:$CARRIER_PORT | wc -l
   ;;
 logs)
   journalctl -u 'frpc-shard@*' --since '-10 minutes' --no-pager | tail -200
   ;;
 *) echo 'Usage: frp-shardctl {status|logs}' >&2; exit 2;;
esac
EOF
  chmod 0755 /usr/local/bin/frp-shardctl
}

install_foreign(){
  require_base
  load_bundle
  timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null || die "Xray not listening on 127.0.0.1:443; nothing changed"
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || die "system CA bundle missing"

  install -d -m 0700 "$SHARD_DIR" "$LOG_DIR"
  umask 077
  printf '%s\n' "$TOKEN" >"$SHARD_DIR/token"
  chmod 0600 "$SHARD_DIR/token"

  for i in $(seq -w 1 "$SHARDS"); do
    cat >"$SHARD_DIR/frpc-$i.toml" <<EOF
clientID = "frp-shard-$i"
serverAddr = "$IRAN_IP"
serverPort = $CARRIER_PORT
loginFailExit = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$SHARD_DIR/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

transport.protocol = "wss"
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 20
transport.poolCount = $POOL_COUNT
transport.dialServerTimeout = 8
transport.dialServerKeepalive = 30
transport.tls.enable = true
transport.tls.serverName = "$DOMAIN"
transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"
transport.tls.disableCustomTLSFirstByte = true

log.to = "$LOG_DIR/frpc-$i.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true

[[proxies]]
name = "xray-shard-$i"
type = "tcp"
localIP = "127.0.0.1"
localPort = 443
remotePort = $NEW_PROXY_PORT
loadBalancer.group = "xray-sharded-v1"
loadBalancer.groupKey = "$GROUP_KEY"
transport.useEncryption = false
transport.useCompression = false
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 2
healthCheck.maxFailed = 5
healthCheck.intervalSeconds = 2
EOF
    chmod 0600 "$SHARD_DIR/frpc-$i.toml"
  done

  cat >/etc/systemd/system/frpc-shard@.service <<EOF
[Unit]
Description=FRP mux shard %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/frpc -c $SHARD_DIR/frpc-%i.toml
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

  write_foreign_ctl
  systemctl daemon-reload
  for i in $(seq -w 1 "$SHARDS"); do systemctl enable --now "frpc-shard@$i" >/dev/null; done

  ok=0
  for _ in {1..30}; do
    active=0
    for i in $(seq -w 1 "$SHARDS"); do systemctl is-active --quiet "frpc-shard@$i" && active=$((active+1)); done
    if [[ "$active" -eq "$SHARDS" ]] && grep -Rqs 'start proxy success' "$LOG_DIR"/frpc-*.log; then ok=1; break; fi
    sleep 1
  done
  ((ok==1)) || { frp-shardctl status; frp-shardctl logs; die "not all shards became ready"; }

  log "Foreign 16-shard mux layer is up in parallel; legacy frpc-nomux was untouched"
  frp-shardctl status
}

case "$ROLE" in
  iran) install_iran;;
  foreign) install_foreign;;
esac

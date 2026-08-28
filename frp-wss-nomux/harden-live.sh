#!/usr/bin/env bash
set -Eeuo pipefail

# Zero-downtime hardening layer for an existing standalone FRP WSS no-mux install.
# Phase 1: run --role iran (creates parallel hardened FRPS + mTLS routing, keeps old FRP alive)
# Phase 2: copy generated bundle + this script to Foreign and run --role foreign
# Phase 3: on Iran run: frp-hardenctl cutover
# Phase 4: wait for old user streams to drain, then: frp-hardenctl seal

BASE_DIR="/etc/frp-nomux"
HARD_DIR="/etc/frp-hardened"
LOG_DIR="/var/log/frp-hardened"
BIN_DIR="/opt/frp-nomux/bin"
NGINX_MAIN="/etc/nginx/conf.d/frp-nomux.conf"
NGINX_MAP="/etc/nginx/conf.d/00-frp-hardened-map.conf"
HAPROXY="/etc/haproxy/haproxy.cfg"
OLD_FRPS_PORT=18081
OLD_PROXY_PORT=10445
NEW_FRPS_PORT=18082
NEW_PROXY_PORT=10446
POOL_COUNT=20
MAX_POOL_COUNT=50
BUNDLE_OUT="/root/frp-hardened-bundle.tar.gz"
ROLE=""
IRAN_IP=""
DOMAIN=""
BUNDLE=""

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

usage(){ cat <<'EOF'
IRAN:
  bash harden-live.sh --role iran --iran-ip 185.215.230.204 --domain aeg.biya2film.top
FOREIGN:
  bash harden-live.sh --role foreign --bundle /root/frp-hardened-bundle.tar.gz
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
backup_dir(){ local d="/root/frp-hardened-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$d"; echo "$d"; }

require_base(){
  [[ -x "$BIN_DIR/frps" && -x "$BIN_DIR/frpc" ]] || die "existing FRP binaries not found in $BIN_DIR"
}

make_mtls(){
  install -d -m 0700 "$HARD_DIR"
  if [[ -s "$HARD_DIR/client-ca.crt" && -s "$HARD_DIR/client.crt" && -s "$HARD_DIR/client.key" ]]; then
    log "existing mTLS identity found"
    return
  fi
  umask 077
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$HARD_DIR/client-ca.key" >/dev/null 2>&1
  openssl req -x509 -new -sha256 -days 3650 \
    -key "$HARD_DIR/client-ca.key" \
    -subj "/CN=FRP Internal Client CA" \
    -out "$HARD_DIR/client-ca.crt" >/dev/null 2>&1
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$HARD_DIR/client.key" >/dev/null 2>&1
  openssl req -new -sha256 -key "$HARD_DIR/client.key" \
    -subj "/CN=frp-edge-client" -out "$HARD_DIR/client.csr" >/dev/null 2>&1
  cat >"$HARD_DIR/client.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyAgreement
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
  openssl x509 -req -sha256 -days 825 \
    -in "$HARD_DIR/client.csr" \
    -CA "$HARD_DIR/client-ca.crt" \
    -CAkey "$HARD_DIR/client-ca.key" \
    -CAcreateserial \
    -extfile "$HARD_DIR/client.ext" \
    -out "$HARD_DIR/client.crt" >/dev/null 2>&1
  chmod 0600 "$HARD_DIR/client-ca.key" "$HARD_DIR/client.key"
  chmod 0644 "$HARD_DIR/client-ca.crt" "$HARD_DIR/client.crt"
  rm -f "$HARD_DIR/client.csr" "$HARD_DIR/client.ext" "$HARD_DIR/client-ca.srl"
  log "private mTLS client identity created"
}

write_frps_hardened(){
  [[ -s "$HARD_DIR/token" ]] || { umask 077; openssl rand -hex 32 >"$HARD_DIR/token"; }
  chmod 0600 "$HARD_DIR/token"
  cat >"$HARD_DIR/frps.toml" <<EOF
bindAddr = "127.0.0.1"
bindPort = $NEW_FRPS_PORT
proxyBindAddr = "127.0.0.1"
transport.maxPoolCount = $MAX_POOL_COUNT
transport.tcpMux = false
transport.tcpKeepalive = 30
transport.tls.force = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$HARD_DIR/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

allowPorts = [{ single = $NEW_PROXY_PORT }]
maxPortsPerClient = 1
userConnTimeout = 10

log.to = "$LOG_DIR/frps.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true
EOF
  chmod 0600 "$HARD_DIR/frps.toml"
}

write_frps_unit(){
  cat >/etc/systemd/system/frps-hardened.service <<EOF
[Unit]
Description=FRP hardened parallel server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/frps -c $HARD_DIR/frps.toml
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

patch_nginx_parallel(){
  local bak="$1"
  cp -a "$NGINX_MAIN" "$bak/frp-nomux.conf"
  [[ -e "$NGINX_MAP" ]] && cp -a "$NGINX_MAP" "$bak/00-frp-hardened-map.conf"

  cat >"$NGINX_MAP" <<EOF
# During drain: legacy FRPC (no client cert) -> old FRPS; mTLS FRPC -> hardened FRPS.
map \$ssl_client_verify \$frp_mtls_upstream {
    default http://127.0.0.1:$OLD_FRPS_PORT;
    SUCCESS http://127.0.0.1:$NEW_FRPS_PORT;
}
EOF

  python3 - "$NGINX_MAIN" "$HARD_DIR/client-ca.crt" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1]); ca=sys.argv[2]
s=p.read_text()
if 'ssl_client_certificate ' not in s:
    marker=re.search(r'(?m)^\s*ssl_protocols\s+[^;]+;\s*$',s)
    if not marker: raise SystemExit('ssl_protocols line not found')
    add=("\n    ssl_client_certificate "+ca+";\n"
         "    ssl_verify_client optional;\n"
         "    ssl_verify_depth 1;\n")
    s=s[:marker.end()]+add+s[marker.end():]
# Carrier endpoint is only FRPC, so TLS 1.3-only is safe and hides post-ServerHello auth details.
s=re.sub(r'(?m)^\s*ssl_protocols\s+[^;]+;\s*$', '    ssl_protocols TLSv1.3;', s, count=1)
s=s.replace('proxy_pass http://127.0.0.1:18081;', 'proxy_pass $frp_mtls_upstream;')
p.write_text(s)
PY

  if ! nginx -t; then
    cp -a "$bak/frp-nomux.conf" "$NGINX_MAIN"
    if [[ -e "$bak/00-frp-hardened-map.conf" ]]; then cp -a "$bak/00-frp-hardened-map.conf" "$NGINX_MAP"; else rm -f "$NGINX_MAP"; fi
    die "nginx validation failed; restored previous config"
  fi
  systemctl reload nginx
  log "Nginx reloaded gracefully; existing WSS sessions remain on old workers"
}

make_bundle(){
  local tmp
  tmp="$(mktemp -d)"
  umask 077
  cat >"$tmp/frp-hardened.env" <<EOF
ROLE='foreign'
IRAN_IP='$IRAN_IP'
DOMAIN='$DOMAIN'
TOKEN='$(cat "$HARD_DIR/token")'
NEW_PROXY_PORT='$NEW_PROXY_PORT'
EOF
  cp -a "$HARD_DIR/client.crt" "$tmp/client.crt"
  cp -a "$HARD_DIR/client.key" "$tmp/client.key"
  chmod 0600 "$tmp/frp-hardened.env" "$tmp/client.key"
  chmod 0644 "$tmp/client.crt"
  tar -C "$tmp" -czf "$BUNDLE_OUT" frp-hardened.env client.crt client.key
  chmod 0600 "$BUNDLE_OUT"
  rm -rf "$tmp"
}

write_ctl(){
  cat >/usr/local/bin/frp-hardenctl <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
H=/etc/haproxy/haproxy.cfg
N=/etc/nginx/conf.d/frp-nomux.conf
OLD=10445
NEW=10446
backup(){ local f="$1"; local b="${f}.bak.$(date +%Y%m%d-%H%M%S)"; cp -a "$f" "$b"; echo "$b"; }
replace_backend(){
  local port="$1" name="$2"
  python3 - "$H" "$port" "$name" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); port=sys.argv[2]; name=sys.argv[3]
lines=p.read_text().splitlines(); out=[]; inside=False; done=False
for x in lines:
    if re.match(r'^backend\s+frp_user_gateway\s*$',x): inside=True; out.append(x); continue
    if inside and re.match(r'^(backend|frontend|listen|global|defaults)\b',x): inside=False
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
  haproxy -c -f "$H" >/dev/null || { cp -a "$b" "$H"; echo '[x] invalid HAProxy config; restored' >&2; exit 1; }
  systemctl reload haproxy
}
old_count(){ ss -Htn state established dst 127.0.0.1:$OLD 2>/dev/null | wc -l; }
new_count(){ ss -Htn state established dst 127.0.0.1:$NEW 2>/dev/null | wc -l; }
case "${1:-status}" in
 status)
  echo '=== HARDENED FRPS ==='; systemctl is-active frps-hardened || true
  echo '=== HARDENED USER PROXY ==='; ss -Hlnpt | grep -q "127.0.0.1:$NEW " && echo UP || echo DOWN
  echo '=== CURRENT USER BACKEND ==='; awk '/^backend frp_user_gateway$/{p=1;next} p&&/^(backend|frontend|listen|global|defaults)/{exit} p&&/^[[:space:]]*server[[:space:]]/{print}' "$H"
  echo "old-streams($(date +%T)): $(old_count)"
  echo "new-streams($(date +%T)): $(new_count)"
  echo -n 'sealed: '; grep -q 'FRP_HARDENED_SEAL' "$N" && echo YES || echo NO
  ;;
 cutover)
  ss -Hlnpt | grep -q "127.0.0.1:$NEW " || { echo '[x] hardened proxy is DOWN; refusing cutover' >&2; exit 1; }
  b="$(backup "$H")"; replace_backend "$NEW" frp_hardened; reload_haproxy "$b"
  echo '[+] Graceful HAProxy reload completed. New user TCP connections use hardened FRP.'
  echo '[i] Old user TCP connections continue through the legacy FRP until they naturally close.'
  ;;
 rollback)
  grep -q 'FRP_HARDENED_SEAL' "$N" && { echo '[x] endpoint is sealed; run unseal before rollback' >&2; exit 1; }
  ss -Hlnpt | grep -q "127.0.0.1:$OLD " || { echo '[x] legacy proxy is DOWN; refusing rollback' >&2; exit 1; }
  b="$(backup "$H")"; replace_backend "$OLD" frp_user; reload_haproxy "$b"
  echo '[+] New connections use legacy FRP again; existing hardened connections are not killed.'
  ;;
 drain)
  echo "legacy established user streams : $(old_count)"
  echo "hardened established user streams: $(new_count)"
  ;;
 seal)
  grep -q '127.0.0.1:10446' "$H" || { echo '[x] production backend is not hardened; refusing seal' >&2; exit 1; }
  c="$(old_count)"; [[ "$c" == 0 ]] || { echo "[x] legacy still has $c established user streams; wait and retry" >&2; exit 1; }
  grep -q 'FRP_HARDENED_SEAL' "$N" && { echo '[i] already sealed'; exit 0; }
  b="$(backup "$N")"
  python3 - "$N" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
needle='    location = /~!frp {\n'
if needle not in s: raise SystemExit('FRP websocket location not found')
insert=('    location = /~!frp {\n'
        '        # FRP_HARDENED_SEAL: active probes without our mTLS client cert get the same 404 as unknown paths.\n'
        '        if ($ssl_client_verify != SUCCESS) { return 404; }\n')
s=s.replace(needle,insert,1)
p.write_text(s)
PY
  nginx -t >/dev/null || { cp -a "$b" "$N"; echo '[x] nginx validation failed; restored' >&2; exit 1; }
  systemctl reload nginx
  echo '[+] Hardened endpoint sealed. Existing sessions were not killed.'
  ;;
 unseal)
  grep -q 'FRP_HARDENED_SEAL' "$N" || { echo '[i] already unsealed'; exit 0; }
  b="$(backup "$N")"
  python3 - "$N" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s=re.sub(r'\n\s*# FRP_HARDENED_SEAL:[^\n]*\n\s*if \(\$ssl_client_verify != SUCCESS\) \{ return 404; \}', '', s, count=1)
p.write_text(s)
PY
  nginx -t >/dev/null || { cp -a "$b" "$N"; echo '[x] nginx validation failed; restored' >&2; exit 1; }
  systemctl reload nginx
  echo '[+] Legacy no-cert FRPC fallback re-enabled for rollback.'
  ;;
 *) echo 'Usage: frp-hardenctl {status|cutover|rollback|drain|seal|unseal}' >&2; exit 2;;
esac
EOF
  chmod 0755 /usr/local/bin/frp-hardenctl
}

install_iran(){
  valid_ip "$IRAN_IP" || die "invalid --iran-ip"
  valid_domain "$DOMAIN" || die "invalid --domain"
  require_base
  [[ -f "$NGINX_MAIN" && -f "$HAPROXY" ]] || die "existing standalone FRP Nginx/HAProxy configs not found"
  systemctl is-active --quiet frps-nomux || die "legacy frps-nomux is not active"
  systemctl is-active --quiet nginx || die "nginx is not active"
  systemctl is-active --quiet haproxy || die "haproxy is not active"
  ss -Hlnpt | grep -q "127.0.0.1:$OLD_PROXY_PORT " || die "legacy FRP user proxy $OLD_PROXY_PORT is not UP"
  ss -Hlnpt | grep -q "127.0.0.1:$NEW_FRPS_PORT " && die "port $NEW_FRPS_PORT already in use"
  ss -Hlnpt | grep -q "127.0.0.1:$NEW_PROXY_PORT " && die "port $NEW_PROXY_PORT already in use"

  install -d -m 0700 "$HARD_DIR"
  install -d -m 0755 "$LOG_DIR"
  make_mtls
  write_frps_hardened
  write_frps_unit
  systemctl daemon-reload
  systemctl enable --now frps-hardened >/dev/null
  sleep 1
  systemctl is-active --quiet frps-hardened || die "frps-hardened failed"

  local bak; bak="$(backup_dir)"
  patch_nginx_parallel "$bak"
  make_bundle
  write_ctl

  log "Iran hardening layer installed in parallel; production users are still on legacy FRP"
  echo "[+] Bundle for Foreign: $BUNDLE_OUT"
  echo "[i] Nothing has been cut over yet. Copy the bundle + this script to Foreign."
  frp-hardenctl status
}

safe_extract_bundle(){
  local src="$1" dst="$2"
  [[ -f "$src" ]] || die "bundle not found: $src"
  local bad
  bad="$(tar -tzf "$src" | grep -E '(^/|(^|/)\.\.(/|$))' || true)"
  [[ -z "$bad" ]] || die "unsafe bundle paths"
  tar -xzf "$src" -C "$dst"
}

install_foreign(){
  require_base
  [[ -n "$BUNDLE" ]] || die "--bundle required"
  systemctl is-active --quiet frpc-nomux || die "legacy frpc-nomux is not active"
  timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null || die "Xray is not listening on 127.0.0.1:443"
  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || die "system CA bundle missing"

  local tmp; tmp="$(mktemp -d)"
  safe_extract_bundle "$BUNDLE" "$tmp"
  # shellcheck disable=SC1090
  source "$tmp/frp-hardened.env"
  [[ "${ROLE:-}" == foreign ]] || die "invalid bundle role"
  valid_ip "$IRAN_IP" || die "invalid IRAN_IP in bundle"
  valid_domain "$DOMAIN" || die "invalid DOMAIN in bundle"
  [[ "${TOKEN:-}" =~ ^[0-9a-f]{64}$ ]] || die "invalid token"

  install -d -m 0700 "$HARD_DIR"
  install -d -m 0755 "$LOG_DIR"
  umask 077
  printf '%s\n' "$TOKEN" >"$HARD_DIR/token"
  install -m 0644 "$tmp/client.crt" "$HARD_DIR/client.crt"
  install -m 0600 "$tmp/client.key" "$HARD_DIR/client.key"

  cat >"$HARD_DIR/frpc.toml" <<EOF
clientID = "frp-hardened-primary"
serverAddr = "$IRAN_IP"
serverPort = 443
loginFailExit = false

auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "$HARD_DIR/token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

transport.protocol = "wss"
transport.tcpMux = false
transport.poolCount = $POOL_COUNT
transport.dialServerTimeout = 8
transport.dialServerKeepalive = 30
transport.tls.enable = true
transport.tls.serverName = "$DOMAIN"
transport.tls.certFile = "$HARD_DIR/client.crt"
transport.tls.keyFile = "$HARD_DIR/client.key"
transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"
transport.tls.disableCustomTLSFirstByte = true

log.to = "$LOG_DIR/frpc.log"
log.level = "info"
log.maxDays = 7
log.disablePrintColor = true

[[proxies]]
name = "xray-tcp-hardened"
type = "tcp"
localIP = "127.0.0.1"
localPort = 443
remotePort = $NEW_PROXY_PORT
transport.useEncryption = false
transport.useCompression = false
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 2
healthCheck.maxFailed = 5
healthCheck.intervalSeconds = 2
EOF
  chmod 0600 "$HARD_DIR/frpc.toml" "$HARD_DIR/token"

  cat >/etc/systemd/system/frpc-hardened.service <<EOF
[Unit]
Description=FRP hardened parallel client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/frpc -c $HARD_DIR/frpc.toml
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadOnlyPaths=/etc/ssl/certs
ReadWritePaths=$LOG_DIR

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now frpc-hardened >/dev/null
  local ok=0
  for _ in {1..20}; do
    if grep -Eq 'login to server success|start proxy success' "$LOG_DIR/frpc.log" 2>/dev/null; then ok=1; break; fi
    sleep 1
  done
  if ((ok == 0)); then
    tail -n 80 "$LOG_DIR/frpc.log" 2>/dev/null || true
    die "hardened frpc did not register; legacy frpc was left untouched"
  fi
  rm -rf "$tmp"
  log "Foreign hardened FRPC is online in parallel; legacy FRPC remains active"
  echo "[+] TLS server certificate verification: ENABLED via system CA bundle"
  echo "[+] mTLS client certificate: ENABLED"
  echo "[i] Now go to Iran and run: frp-hardenctl status"
}

case "$ROLE" in
  iran) install_iran;;
  foreign) install_foreign;;
esac

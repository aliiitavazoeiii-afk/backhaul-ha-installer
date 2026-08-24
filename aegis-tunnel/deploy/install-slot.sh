#!/usr/bin/env bash
set -Eeuo pipefail

REPO='aliiitavazoeiii-afk/backhaul-ha-installer'
SOURCE_PIN='93c437959fc1892ee36e6b13d0e84b43ab0ff641'
ROLE=''; SLOT=''; BUNDLE=''

log(){ printf '[+] %s\n' "$*"; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --slot) SLOT="${2:-}"; shift 2;;
    --bundle) BUNDLE="${2:-}"; shift 2;;
    *) die "Unknown option: $1";;
  esac
done
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run as root.'
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || die '--role iran|foreign required.'
[[ "$SLOT" == a || "$SLOT" == b ]] || { [[ -n "$BUNDLE" ]] || die '--slot a|b required.'; }

build_aegis(){
  if [[ -x /usr/local/bin/aegis ]] && [[ "$(/usr/local/bin/aegis -version 2>/dev/null || true)" == 0.1.0 ]]; then return; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl ca-certificates tar golang-1.23-go >/dev/null
  local d=/tmp/aegis-build-$$ tgz=/tmp/aegis-src-$$.tgz
  rm -rf "$d" "$tgz"; mkdir -p "$d"
  curl -fL --retry 4 --retry-delay 2 "https://github.com/${REPO}/archive/${SOURCE_PIN}.tar.gz" -o "$tgz"
  tar -xzf "$tgz" -C "$d" --strip-components=1
  cd "$d/aegis-tunnel"
  /usr/lib/go-1.23/bin/go test ./...
  CGO_ENABLED=0 /usr/lib/go-1.23/bin/go build -trimpath -ldflags='-s -w' -o /usr/local/bin/aegis ./cmd/aegis
  chmod 0755 /usr/local/bin/aegis
  cd /
  rm -rf "$d" "$tgz"
  [[ "$(/usr/local/bin/aegis -version)" == 0.1.0 ]] || die 'Aegis build verification failed.'
}

slot_meta(){
  if [[ "$SLOT" == a ]]; then
    HTTP_PORT=38080; DATA_PORT=30443; HEALTH_PORT=30444; NGINX_PORT=9080
    OLD_BUNDLE=/root/dual-stealth-a.env; AEGIS_BUNDLE=/root/aegis-a.env; SERVICE=aegis-a-server
  else
    HTTP_PORT=39080; DATA_PORT=31443; HEALTH_PORT=31444; NGINX_PORT=9081
    OLD_BUNDLE=/root/dual-stealth-b.env; AEGIS_BUNDLE=/root/aegis-b.env; SERVICE=aegis-b-server
  fi
}

get_env(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$2" | head -n1; }

install_iran(){
  slot_meta
  [[ -f "$OLD_BUNDLE" ]] || die "Existing stable slot bundle missing: $OLD_BUNDLE"
  [[ -f /etc/nginx/sites-available/dual-wss-stealth ]] || die 'Dual WSS nginx site missing.'
  build_aegis
  install -d -m 0700 /etc/aegis
  local domain token path
  domain="$(get_env DOMAIN "$OLD_BUNDLE")"; [[ -n "$domain" ]] || die 'DOMAIN missing in stable bundle.'
  token="$(openssl rand -hex 32)"
  path="/edge/v1/$(openssl rand -hex 20)"
  cat > "/etc/aegis/${SLOT}-server.json" <<JSON
{
  "bind": "127.0.0.1:${HTTP_PORT}",
  "token": "${token}",
  "path_prefix": "${path}",
  "keepalive_seconds": 25,
  "listeners": [
    {"listen":"127.0.0.1:${DATA_PORT}","target_id":1},
    {"listen":"127.0.0.1:${HEALTH_PORT}","target_id":2}
  ]
}
JSON
  chmod 0600 "/etc/aegis/${SLOT}-server.json"
  cat > "$AEGIS_BUNDLE" <<EOFENV
SLOT='$SLOT'
DOMAIN='$domain'
TOKEN='$token'
PATH_PREFIX='$path'
EOFENV
  chmod 0600 "$AEGIS_BUNDLE"

  cat > "/etc/systemd/system/${SERVICE}.service" <<EOFUNIT
[Unit]
Description=Aegis Tunnel slot ${SLOT^^} server
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/aegis -role server -config /etc/aegis/${SLOT}-server.json
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOFUNIT

  install -d -m 0700 /root/dual-stealth-panel-backups
  cp -a /etc/nginx/sites-available/dual-wss-stealth "/root/dual-stealth-panel-backups/nginx.before-aegis-${SLOT}-$(date +%Y%m%d-%H%M%S).conf"
  python3 - "$NGINX_PORT" "$path" "$HTTP_PORT" <<'PY'
from pathlib import Path
import sys
p=Path('/etc/nginx/sites-available/dual-wss-stealth')
port,path,up=sys.argv[1],sys.argv[2],sys.argv[3]
s=p.read_text()
pos=s.find(f'listen 127.0.0.1:{port};')
if pos<0: raise SystemExit('target nginx server block not found')
start=s.rfind('server {',0,pos)
if start<0: raise SystemExit('server block start not found')
depth=0; end=None
for i in range(start,len(s)):
    if s[i]=='{': depth+=1
    elif s[i]=='}':
        depth-=1
        if depth==0: end=i+1; break
if end is None: raise SystemExit('server block end not found')
block=s[start:end]
marker=f'location ^~ {path}/'
if marker in block: raise SystemExit(0)
loc=f'''\n    # Aegis independent transport canary\n    location ^~ {path}/ {{\n        proxy_http_version 1.1;\n        proxy_set_header Host $host;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";\n        proxy_set_header Authorization $http_authorization;\n        proxy_read_timeout 1d; proxy_send_timeout 1d;\n        proxy_buffering off; proxy_request_buffering off;\n        proxy_pass http://127.0.0.1:{up};\n    }}\n'''
idx=block.rfind('    location /')
if idx<0: raise SystemExit('fallback location not found in server block')
block=block[:idx]+loc+block[idx:]
p.write_text(s[:start]+block+s[end:])
PY
  nginx -t
  systemctl daemon-reload
  systemctl enable --now "$SERVICE" >/dev/null
  systemctl reload nginx
  log "Aegis slot ${SLOT^^} Iran canary installed."
  echo "[NEXT] scp $AEGIS_BUNDLE root@FOREIGN_IP:$AEGIS_BUNDLE"
  echo "[CANARY] local data 127.0.0.1:$DATA_PORT health 127.0.0.1:$HEALTH_PORT"
}

install_foreign(){
  [[ -n "$BUNDLE" && -f "$BUNDLE" ]] || die '--bundle file required on Foreign.'
  SLOT="$(get_env SLOT "$BUNDLE")"; [[ "$SLOT" == a || "$SLOT" == b ]] || die 'Invalid SLOT in bundle.'
  slot_meta; build_aegis; install -d -m 0700 /etc/aegis
  local domain token path
  domain="$(get_env DOMAIN "$BUNDLE")"; token="$(get_env TOKEN "$BUNDLE")"; path="$(get_env PATH_PREFIX "$BUNDLE")"
  [[ -n "$domain" && -n "$token" && -n "$path" ]] || die 'Incomplete Aegis bundle.'
  cat > /etc/aegis/client.json <<JSON
{
  "remote_addr": "${domain}:443",
  "edge_ip": "",
  "scheme": "wss",
  "tls_server_name": "${domain}",
  "tls_skip_verify": false,
  "token": "${token}",
  "path_prefix": "${path}",
  "origin": "https://${domain}",
  "pool": 4,
  "dial_timeout_seconds": 10,
  "keepalive_seconds": 25,
  "targets": [
    {"id":1,"address":"127.0.0.1:443"},
    {"id":2,"address":"127.0.0.1:18090"}
  ]
}
JSON
  chmod 0600 /etc/aegis/client.json
  cat > /etc/systemd/system/aegis-client.service <<'EOFUNIT'
[Unit]
Description=Aegis Tunnel Foreign client
After=network-online.target dual-stealth-health.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/aegis -role client -config /etc/aegis/client.json
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOFUNIT
  systemctl daemon-reload
  systemctl enable --now aegis-client >/dev/null
  sleep 2
  log "Aegis Foreign-${SLOT^^} canary client installed alongside current tunnel."
  systemctl is-active aegis-client
}

if [[ "$ROLE" == iran ]]; then install_iran; else install_foreign; fi

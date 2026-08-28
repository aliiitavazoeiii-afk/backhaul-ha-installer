#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_URL="https://github.com/aliiitavazoeiii-afk/backhaul-ha-installer.git"
BRANCH="agent/dragon-shield-v1"
RAW_BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${BRANCH}/dragon-shield"
BIN="/usr/local/bin/dragon-shield"
ETC_DIR="/etc/dragon-shield"
SERVICE="/etc/systemd/system/dragon-shield.service"

log(){ printf '[dragon-shield-repair] %s\n' "$*"; }
die(){ printf '[dragon-shield-repair] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"

DOMAIN=""
CLIENT_ID="iran1"
CLIENT_IP="10.203.0.2"
SERVER_CIDR="10.203.0.1/24"
MTU="1080"

while (($#)); do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --client-id) CLIENT_ID="${2:-}"; shift 2 ;;
    --client-ip) CLIENT_IP="${2:-}"; shift 2 ;;
    --server-cidr) SERVER_CIDR="${2:-}"; shift 2 ;;
    --mtu) MTU="${2:-}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$DOMAIN" ]] || die "--domain is required"
command -v git >/dev/null 2>&1 || die "git is missing"
command -v go >/dev/null 2>&1 || die "go is missing"
command -v python3 >/dev/null 2>&1 || die "python3 is missing"
command -v openssl >/dev/null 2>&1 || die "openssl is missing"

python3 - "$SERVER_CIDR" "$CLIENT_IP" <<'PY'
import ipaddress, sys
iface=ipaddress.ip_interface(sys.argv[1])
ip=ipaddress.ip_address(sys.argv[2])
if ip not in iface.network:
    raise SystemExit('client IP is outside server subnet')
if ip == iface.ip:
    raise SystemExit('client IP cannot equal server IP')
PY

CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
if [[ ! -r "$CERT" || ! -r "$KEY" ]]; then
  command -v certbot >/dev/null 2>&1 || die "certificate not found and certbot is missing"
  log "requesting certificate for ${DOMAIN}"
  certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$DOMAIN" >&2
fi
[[ -r "$CERT" && -r "$KEY" ]] || die "certificate files are unreadable"

TMP="$(mktemp -d -t dragon-shield-repair.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
log "building latest Dragon Shield"
git clone -q --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP/src"
cd "$TMP/src/dragon-shield"
export PATH="/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
GOTOOLCHAIN=local go mod tidy
GOTOOLCHAIN=local go build -trimpath -ldflags='-s -w' -o "$TMP/dragon-shield" ./cmd/dragon-shield
install -m 0755 "$TMP/dragon-shield" "${BIN}.new"
mv -f "${BIN}.new" "$BIN"

mkdir -p "$ETC_DIR"
TOKEN="$(openssl rand -base64 36 | tr -d '\n')"
WT_PATH="/assets/$(openssl rand -hex 12)"
WS_PATH="/api/events/$(openssl rand -hex 12)"

DOMAIN="$DOMAIN" CLIENT_ID="$CLIENT_ID" CLIENT_IP="$CLIENT_IP" SERVER_CIDR="$SERVER_CIDR" MTU="$MTU" CERT="$CERT" KEY="$KEY" TOKEN="$TOKEN" WT_PATH="$WT_PATH" WS_PATH="$WS_PATH" \
python3 - "$ETC_DIR/server.json" <<'PY'
import json, os, sys
cfg={
    'role':'server',
    'listen':':443',
    'public_domain':os.environ['DOMAIN'],
    'tls_cert':os.environ['CERT'],
    'tls_key':os.environ['KEY'],
    'tun_name':'dfrshield0',
    'tun_cidr':os.environ['SERVER_CIDR'],
    'mtu':int(os.environ['MTU']),
    'webtransport_path':os.environ['WT_PATH'],
    'websocket_path':os.environ['WS_PATH'],
    'clients':[{
        'id':os.environ['CLIENT_ID'],
        'ip':os.environ['CLIENT_IP'],
        'token':os.environ['TOKEN'],
    }],
}
with open(sys.argv[1],'w') as f:
    json.dump(cfg,f,indent=2)
    f.write('\n')
PY
chmod 0600 "$ETC_DIR/server.json"

cat >"$SERVICE" <<UNIT
[Unit]
Description=Dragon Shield server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=${BIN} prepare-tun -config ${ETC_DIR}/server.json
ExecStart=${BIN} server -config ${ETC_DIR}/server.json
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

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 443/udp >/dev/null || true
  ufw allow 8443/tcp >/dev/null || true
  ufw allow 80/tcp >/dev/null || true
fi

systemctl daemon-reload
systemctl enable dragon-shield.service >/dev/null
systemctl restart dragon-shield.service
sleep 2
if ! systemctl is-active --quiet dragon-shield.service; then
  systemctl status dragon-shield.service --no-pager -l || true
  journalctl -u dragon-shield.service -n 80 --no-pager || true
  die "Dragon Shield failed to start"
fi

ENROLL="$(python3 - "$ETC_DIR/server.json" "$CLIENT_ID" <<'PY'
import base64, ipaddress, json, sys
cfg=json.load(open(sys.argv[1]))
cid=sys.argv[2]
client=next(x for x in cfg['clients'] if x['id']==cid)
iface=ipaddress.ip_interface(cfg['tun_cidr'])
payload={
    'v':1,
    'server':f"{cfg['public_domain']}:443",
    'server_name':cfg['public_domain'],
    'server_tun_ip':str(iface.ip),
    'tun_cidr':f"{client['ip']}/{iface.network.prefixlen}",
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
)"
printf '%s\n' "$ENROLL" >"/root/dragon-shield-enroll-${CLIENT_ID}.txt"
chmod 0600 "/root/dragon-shield-enroll-${CLIENT_ID}.txt"

log "server is running"
echo "QUIC/WebTransport: UDP/443"
echo "WSS fallback:       TCP/8443"
echo "TCP/443:            untouched (available for Xray)"
echo
echo "=== CLIENT ENROLLMENT ==="
echo "$ENROLL"
echo
echo "Run on Iran:"
printf "bash <(curl -fsSL %q) client --enroll %q\n" "${RAW_BASE}/install.sh" "$ENROLL"
echo
echo "Verify foreign listeners:"
echo "  ss -lntup | grep -E ':(443|8443)\\b'"
echo "Logs: journalctl -u dragon-shield -n 50 --no-pager"

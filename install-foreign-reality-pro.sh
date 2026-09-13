#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-}"
case "$ROLE" in f1|f2) ;; *) echo "Usage: $0 f1|f2"; exit 2 ;; esac

XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
XRAY_SHA256="${XRAY_SHA256:-}"
INSTALL_DIR="/usr/local/lib/reality-pro"
CONFIG_DIR="/etc/reality-pro-server"
SERVICE="reality-pro-server.service"
PORT="${REALITY_PRO_PORT:-443}"
FORCE_NEW_CREDENTIALS="${FORCE_NEW_CREDENTIALS:-1}"
CLIENT_ENV="/root/reality-pro-client.env"
SERVER_ENV="/root/reality-pro-server-secrets.env"
FINGERPRINT="${REALITY_FINGERPRINT:-$([[ "$ROLE" == f1 ]] && echo chrome || echo firefox)}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT>=1 && PORT<=65535 )) || { echo "Invalid port"; exit 1; }
for c in curl python3 systemctl; do command -v "$c" >/dev/null || { echo "Missing command: $c"; exit 1; }; done

case "$(uname -m)" in
  x86_64|amd64) ASSET="Xray-linux-64.zip"; [[ -n "$XRAY_SHA256" ]] || [[ "$XRAY_VERSION" != "v26.3.27" ]] || XRAY_SHA256="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae" ;;
  aarch64|arm64) ASSET="Xray-linux-arm64-v8a.zip"; [[ -n "$XRAY_SHA256" ]] || [[ "$XRAY_VERSION" != "v26.3.27" ]] || XRAY_SHA256="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c" ;;
  *) echo "Unsupported architecture"; exit 1 ;;
esac
[[ -n "$XRAY_SHA256" ]] || { echo "Set XRAY_SHA256 for custom Xray version"; exit 1; }

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" /var/lib/reality-pro-server/backups
chmod 700 "$CONFIG_DIR" /var/lib/reality-pro-server /var/lib/reality-pro-server/backups
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ASSET}"
echo "[1/9] Installing verified Xray ${XRAY_VERSION}..."
curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 180 "$URL" -o "$TMP/xray.zip"
python3 - "$TMP/xray.zip" "$XRAY_SHA256" <<'PY'
import hashlib,sys,zipfile,os
p,e=sys.argv[1:]
g=hashlib.sha256(open(p,'rb').read()).hexdigest()
if g!=e: raise SystemExit(f'SHA256 mismatch: {g} != {e}')
print('SHA256 verified:',g)
PY
python3 - "$TMP/xray.zip" "$TMP" <<'PY'
import zipfile,sys,os
src,dst=sys.argv[1:]
with zipfile.ZipFile(src) as z: z.extractall(dst+'/xray')
if not os.path.isfile(dst+'/xray/xray'): raise SystemExit('xray binary missing')
PY
install -m 0755 "$TMP/xray/xray" "$INSTALL_DIR/xray"
"$INSTALL_DIR/xray" version | sed -n '1p'

if [[ -n "${REALITY_TARGET:-}" ]]; then
  TARGET_CANDIDATES=("$REALITY_TARGET")
elif [[ "$ROLE" == f1 ]]; then
  TARGET_CANDIDATES=("dl.google.com:443" "www.microsoft.com:443" "www.apple.com:443")
else
  TARGET_CANDIDATES=("www.apple.com:443" "www.microsoft.com:443" "dl.google.com:443")
fi

echo "[2/9] Selecting and validating a REALITY target for ${ROLE^^}..."
REALITY_TARGET=""; REALITY_SNI=""
for cand in "${TARGET_CANDIDATES[@]}"; do
  host="${cand%:*}"
  echo "  trying $cand"
  if timeout 18 "$INSTALL_DIR/xray" tls ping "$host" >/dev/null 2>&1 && curl -4 -fsS -o /dev/null --connect-timeout 6 --max-time 12 "https://${host}/"; then
    REALITY_TARGET="$cand"; REALITY_SNI="$host"; break
  fi
done
[[ -n "$REALITY_TARGET" ]] || { echo "No candidate target passed TLS validation. Set REALITY_TARGET=host:443 explicitly."; exit 1; }
echo "Selected: $REALITY_TARGET"

if [[ "$FORCE_NEW_CREDENTIALS" != "1" && -f "$CLIENT_ENV" && -f "$SERVER_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$CLIENT_ENV"
  # shellcheck disable=SC1090
  source "$SERVER_ENV"
else
  echo "[3/9] Generating fresh credentials and per-node camouflage values..."
  VLESS_ID="$(python3 - <<'PY'
import uuid; print(uuid.uuid4())
PY
)"
  KO="$("$INSTALL_DIR/xray" x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$KO" | awk -F': ' '/^PrivateKey:/{print $2;exit}')"
  REALITY_PASSWORD="$(printf '%s\n' "$KO" | awk -F': ' '/^(Password|Password \(PublicKey\)):/{print $2;exit}')"
  REALITY_SHORT_ID="$(python3 - <<'PY'
import secrets; print(secrets.token_hex(8))
PY
)"
fi
: "${VLESS_ID:?}"; : "${REALITY_PRIVATE_KEY:?}"; : "${REALITY_PASSWORD:?}"; : "${REALITY_SHORT_ID:?}"

SPIDER_X="$(python3 - "$ROLE" <<'PY'
import secrets,sys
role=sys.argv[1]
base=['/','/robots.txt','/favicon.ico','/assets/']
print(base[secrets.randbelow(len(base))] if role=='f1' else base[(secrets.randbelow(len(base)-1)+1)%len(base)])
PY
)"
read -r UP_AFTER UP_BPS UP_BURST DOWN_AFTER DOWN_BPS DOWN_BURST < <(python3 - <<'PY'
import secrets
m=1024*1024
# Intentionally randomized and only starts after a large transfer so ordinary probes are unaffected.
vals=[
 secrets.randbelow(12*m)+16*m, secrets.randbelow(768*1024)+768*1024, secrets.randbelow(4*m)+4*m,
 secrets.randbelow(16*m)+20*m, secrets.randbelow(1024*1024)+1024*1024, secrets.randbelow(6*m)+5*m,
]
print(*vals)
PY
)

echo "[4/9] Checking TCP ${PORT} availability..."
systemctl stop "$SERVICE" 2>/dev/null || true
python3 - "$PORT" <<'PY'
import socket,sys
p=int(sys.argv[1]); s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
try: s.bind(('0.0.0.0',p))
except OSError as e: raise SystemExit(f'TCP {p} unavailable: {e}')
finally: s.close()
PY

echo "[5/9] Writing REALITY + Vision RAW config with abuse guards..."
cat >"$CONFIG_DIR/server.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "reality-pro-in",
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {"clients": [{"id": "${VLESS_ID}", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "${REALITY_TARGET}",
        "xver": 0,
        "serverNames": ["${REALITY_SNI}"],
        "privateKey": "${REALITY_PRIVATE_KEY}",
        "minClientVer": "26.3.27",
        "shortIds": ["${REALITY_SHORT_ID}"],
        "limitFallbackUpload": {"afterBytes": ${UP_AFTER}, "bytesPerSec": ${UP_BPS}, "burstBytesPerSec": ${UP_BURST}},
        "limitFallbackDownload": {"afterBytes": ${DOWN_AFTER}, "bytesPerSec": ${DOWN_BPS}, "burstBytesPerSec": ${DOWN_BURST}}
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true}
  }],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "blocked", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [
      {"type": "field", "port": "25", "outboundTag": "blocked"},
      {"type": "field", "ip": ["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.168.0.0/16","198.18.0.0/15","224.0.0.0/4","240.0.0.0/4","::1/128","fc00::/7","fe80::/10"], "outboundTag": "blocked"}
    ]
  }
}
EOF
chmod 600 "$CONFIG_DIR/server.json"
python3 -m json.tool "$CONFIG_DIR/server.json" >/dev/null
"$INSTALL_DIR/xray" run -test -c "$CONFIG_DIR/server.json"

cat >"$CLIENT_ENV" <<EOF
ROLE='${ROLE}'
PORT='${PORT}'
VLESS_ID='${VLESS_ID}'
REALITY_PASSWORD='${REALITY_PASSWORD}'
REALITY_SHORT_ID='${REALITY_SHORT_ID}'
SNI='${REALITY_SNI}'
TARGET='${REALITY_TARGET}'
FINGERPRINT='${FINGERPRINT}'
SPIDER_X='${SPIDER_X}'
FLOW='xtls-rprx-vision'
TRANSPORT='raw'
EOF
cat >"$SERVER_ENV" <<EOF
ROLE='${ROLE}'
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'
SNI='${REALITY_SNI}'
TARGET='${REALITY_TARGET}'
EOF
chmod 600 "$CLIENT_ENV" "$SERVER_ENV"

echo "[6/9] Installing isolated systemd service..."
cat >"/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=Reality Pro VLESS REALITY Vision server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xray run -c ${CONFIG_DIR}/server.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then ufw allow "${PORT}/tcp" >/dev/null; fi

echo "[7/9] Listener check..."
ss -lntp "( sport = :${PORT} )"

echo "[8/9] Config self-test..."
"$INSTALL_DIR/xray" run -test -c "$CONFIG_DIR/server.json" >/dev/null

echo "[9/9] Done."
echo "============================================================"
echo "REALITY PRO FOREIGN ${ROLE^^} READY"
echo "Port        : ${PORT}/TCP"
echo "Target/SNI  : ${REALITY_TARGET} / ${REALITY_SNI}"
echo "Fingerprint : ${FINGERPRINT}"
echo "SpiderX     : ${SPIDER_X}"
echo "Service     : ${SERVICE}"
echo "Client env  : ${CLIENT_ENV}"
echo "============================================================"
cat "$CLIENT_ENV"

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_REF="${PROJECT_REF:-xhttp-dual-sticky-failover}"
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
XRAY_SHA256="${XRAY_SHA256:-}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/vision-reality}"
CONFIG_DIR="${CONFIG_DIR:-/etc/vision-reality}"
SERVICE="vision-reality-server.service"
PORT="${VISION_PORT:-443}"
REALITY_TARGET="${REALITY_TARGET:-dl.google.com:443}"
REALITY_SNI="${REALITY_SNI:-${REALITY_TARGET%%:*}}"
FORCE_NEW_CREDENTIALS="${FORCE_NEW_CREDENTIALS:-0}"
CLIENT_ENV="/root/vision-reality-client.env"
SERVER_ENV="/root/vision-reality-server-secrets.env"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
for cmd in curl python3 systemctl; do command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd"; exit 1; }; done
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || { echo "Invalid VISION_PORT: $PORT"; exit 1; }
[[ "$REALITY_TARGET" == *:* ]] || { echo "REALITY_TARGET must be host:port"; exit 1; }
[[ -n "$REALITY_SNI" ]] || { echo "REALITY_SNI is empty"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)
    ASSET="Xray-linux-64.zip"
    [[ -n "$XRAY_SHA256" ]] || [[ "$XRAY_VERSION" != "v26.3.27" ]] || XRAY_SHA256="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
    ;;
  aarch64|arm64)
    ASSET="Xray-linux-arm64-v8a.zip"
    [[ -n "$XRAY_SHA256" ]] || [[ "$XRAY_VERSION" != "v26.3.27" ]] || XRAY_SHA256="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"
    ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac
[[ -n "$XRAY_SHA256" ]] || { echo "Set XRAY_SHA256 for custom Xray version."; exit 1; }

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" /var/lib/vision-reality-backups
chmod 700 "$CONFIG_DIR" /var/lib/vision-reality-backups
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OLD_XHTTP_ACTIVE=0
OLD_DECOY_ACTIVE=0
systemctl is-active --quiet xhttp-reality-server.service 2>/dev/null && OLD_XHTTP_ACTIVE=1 || true
systemctl is-active --quiet xhttp-reality-decoy.service 2>/dev/null && OLD_DECOY_ACTIVE=1 || true

rollback_install() {
  echo
  echo "Vision install failed; restoring previous Foreign services if they were active..."
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  (( OLD_DECOY_ACTIVE == 1 )) && systemctl start xhttp-reality-decoy.service 2>/dev/null || true
  (( OLD_XHTTP_ACTIVE == 1 )) && systemctl start xhttp-reality-server.service 2>/dev/null || true
}
trap rollback_install ERR

echo "[1/8] Installing verified Xray ${XRAY_VERSION}..."
URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ASSET}"
curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 180 "$URL" -o "$TMP/xray.zip"
python3 - "$TMP/xray.zip" "$XRAY_SHA256" <<'PY'
import hashlib, sys
p, expected = sys.argv[1:]
got = hashlib.sha256(open(p,'rb').read()).hexdigest()
if got != expected: raise SystemExit(f'Xray SHA256 mismatch: {got} != {expected}')
print('Xray SHA256 verified:', got)
PY
python3 - "$TMP/xray.zip" "$TMP" <<'PY'
import os, sys, zipfile
src,dst=sys.argv[1:]
with zipfile.ZipFile(src) as z: z.extractall(dst+'/xray')
p=dst+'/xray/xray'
if not os.path.isfile(p): raise SystemExit('xray binary missing')
PY
install -m 0755 "$TMP/xray/xray" "$INSTALL_DIR/xray"
"$INSTALL_DIR/xray" version | sed -n '1p'

echo "[2/8] Stopping old XHTTP Foreign listener on this NEW server, if present..."
systemctl stop xhttp-reality-decoy.service 2>/dev/null || true
systemctl stop xhttp-reality-server.service 2>/dev/null || true
systemctl stop "$SERVICE" 2>/dev/null || true

python3 - "$PORT" <<'PY'
import socket,sys
p=int(sys.argv[1]); s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
try: s.bind(('0.0.0.0',p))
except OSError as e: raise SystemExit(f'TCP {p} unavailable: {e}')
finally: s.close()
PY

if [[ "$FORCE_NEW_CREDENTIALS" != "1" && -f "$CLIENT_ENV" && -f "$SERVER_ENV" ]]; then
  echo "[3/8] Reusing existing Vision credentials..."
  # shellcheck disable=SC1090
  source "$CLIENT_ENV"
  # shellcheck disable=SC1090
  source "$SERVER_ENV"
else
  echo "[3/8] Generating fresh VLESS + REALITY Vision credentials..."
  VLESS_ID="$(python3 - <<'PY'
import uuid; print(uuid.uuid4())
PY
)"
  KEY_OUTPUT="$("$INSTALL_DIR/xray" x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" | awk -F': ' '/^PrivateKey:/{print $2; exit}')"
  REALITY_PASSWORD="$(printf '%s\n' "$KEY_OUTPUT" | awk -F': ' '/^(Password|Password \(PublicKey\)):/{print $2; exit}')"
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PASSWORD" ]] || { printf '%s\n' "$KEY_OUTPUT"; echo "Could not parse x25519 output"; exit 1; }
  REALITY_SHORT_ID="$(python3 - <<'PY'
import secrets; print(secrets.token_hex(8))
PY
)"
fi

: "${VLESS_ID:?}"
: "${REALITY_PRIVATE_KEY:?}"
: "${REALITY_PASSWORD:?}"
: "${REALITY_SHORT_ID:?}"

echo "[4/8] Checking REALITY target ${REALITY_TARGET}..."
TARGET_HOST="${REALITY_TARGET%:*}"
if ! timeout 15 "$INSTALL_DIR/xray" tls ping "$TARGET_HOST" >/tmp/vision-reality-tls-ping.log 2>&1; then
  echo "WARNING: xray tls ping did not complete; checking ordinary TLS with curl..."
  curl -4 -sS -o /dev/null --connect-timeout 7 --max-time 12 "https://${REALITY_SNI}/" || {
    echo "REALITY target/SNI is not reachable from this Foreign."
    echo "Try another target with: REALITY_TARGET=host:443 REALITY_SNI=host $0"
    exit 1
  }
fi

echo "[5/8] Writing VLESS + REALITY + Vision RAW server config..."
cat >"$CONFIG_DIR/server.json" <<EOF_JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "vision-reality-in",
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${VLESS_ID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "${REALITY_TARGET}",
        "xver": 0,
        "serverNames": ["${REALITY_SNI}"],
        "privateKey": "${REALITY_PRIVATE_KEY}",
        "shortIds": ["${REALITY_SHORT_ID}"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
  }],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}]
}
EOF_JSON
chmod 600 "$CONFIG_DIR/server.json"
python3 -m json.tool "$CONFIG_DIR/server.json" >/dev/null
"$INSTALL_DIR/xray" run -test -c "$CONFIG_DIR/server.json"

cat >"$CLIENT_ENV" <<EOF_ENV
PORT='${PORT}'
VLESS_ID='${VLESS_ID}'
REALITY_PASSWORD='${REALITY_PASSWORD}'
REALITY_SHORT_ID='${REALITY_SHORT_ID}'
SNI='${REALITY_SNI}'
FLOW='xtls-rprx-vision'
TRANSPORT='raw'
TARGET='${REALITY_TARGET}'
EOF_ENV
cat >"$SERVER_ENV" <<EOF_ENV
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'
TARGET='${REALITY_TARGET}'
SNI='${REALITY_SNI}'
EOF_ENV
chmod 600 "$CLIENT_ENV" "$SERVER_ENV"

echo "[6/8] Installing systemd service..."
cat >"/etc/systemd/system/${SERVICE}" <<EOF_UNIT
[Unit]
Description=VLESS REALITY Vision RAW Foreign server
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

[Install]
WantedBy=multi-user.target
EOF_UNIT
systemctl daemon-reload
systemctl enable --now "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE"

echo "[7/8] Firewall / listener verification..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
  ufw allow "${PORT}/tcp" >/dev/null
fi
if command -v ss >/dev/null 2>&1; then
  ss -lntp "( sport = :${PORT} )"
fi

echo "[8/8] Done."
trap - ERR

echo
echo "============================================================"
echo "FOREIGN VLESS + REALITY + VISION READY"
echo "Port       : ${PORT}/TCP"
echo "Transport  : RAW"
echo "Flow       : xtls-rprx-vision"
echo "Target/SNI : ${REALITY_TARGET} / ${REALITY_SNI}"
echo "Client env : ${CLIENT_ENV}"
echo "Old XHTTP  : stopped on this Foreign only"
echo "============================================================"
cat "$CLIENT_ENV"

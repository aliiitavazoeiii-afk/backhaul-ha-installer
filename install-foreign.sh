#!/usr/bin/env bash
set -Eeuo pipefail

XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/xhttp-reality}"
CONFIG_DIR="${CONFIG_DIR:-/etc/xhttp-reality}"
SERVICE_NAME="xhttp-reality-server"
XHTTP_PORT="${XHTTP_PORT:-443}"
REALITY_TARGET="${REALITY_TARGET:-www.cloudflare.com:443}"
REALITY_SNI="${REALITY_SNI:-${REALITY_TARGET%%:*}}"
FORCE_NEW_CREDENTIALS="${FORCE_NEW_CREDENTIALS:-0}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

if ! [[ "$XHTTP_PORT" =~ ^[0-9]+$ ]] || (( XHTTP_PORT < 1 || XHTTP_PORT > 65535 )); then
  echo "Invalid XHTTP_PORT: $XHTTP_PORT"
  exit 1
fi

# Deliberately do NOT run apt-get update/install here.
# Fresh Ubuntu/Debian VPS mirrors can be slow/unreachable even while GitHub works,
# and this installer only needs curl + python3 + systemd, which are already present
# on supported hosts in normal deployments. ZIP extraction and JSON validation use
# Python so jq/unzip are not required.
for cmd in curl python3 systemctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command is missing: $cmd"
    echo "Install it manually, then rerun this installer."
    exit 1
  fi
done

case "$(uname -m)" in
  x86_64|amd64) ASSET="Xray-linux-64.zip" ;;
  aarch64|arm64) ASSET="Xray-linux-arm64-v8a.zip" ;;
  *)
    echo "Unsupported architecture: $(uname -m) (supported: amd64, arm64)"
    exit 1
    ;;
esac

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ASSET}"
echo "[1/8] Installing Xray ${XRAY_VERSION} (no apt required)..."
curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 180 "$URL" -o "$TMP/xray.zip"
mkdir -p "$TMP/xray"
python3 - "$TMP/xray.zip" "$TMP/xray" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    z.extractall(dst)
path = os.path.join(dst, 'xray')
if not os.path.isfile(path):
    raise SystemExit('xray binary not found in downloaded archive')
PY
install -m 0755 "$TMP/xray/xray" "$INSTALL_DIR/xray"
XRAY_VERSION_LINE="$("$INSTALL_DIR/xray" version 2>/dev/null | sed -n '1p')"
echo "$XRAY_VERSION_LINE"

systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true

# Check that the requested IPv4 listen port can actually be bound, without
# depending on ss/netstat/iproute2 being installed.
if ! python3 - "$XHTTP_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('0.0.0.0', port))
except OSError as e:
    print(f'TCP port {port} cannot be bound: {e}', file=sys.stderr)
    raise SystemExit(1)
finally:
    s.close()
PY
then
  echo
  echo "TCP port ${XHTTP_PORT} is already in use or unavailable."
  command -v ss >/dev/null 2>&1 && ss -lntp "( sport = :${XHTTP_PORT} )" || true
  echo
  echo "Free the port or rerun with another port, e.g.:"
  echo "  XHTTP_PORT=8443 ./install-foreign.sh"
  exit 1
fi

CLIENT_ENV="/root/xhttp-reality-client.env"
SERVER_ENV="/root/xhttp-reality-server-secrets.env"

if [[ "$FORCE_NEW_CREDENTIALS" != "1" && -f "$CLIENT_ENV" && -f "$SERVER_ENV" ]]; then
  echo "[2/8] Reusing existing tunnel credentials..."
  # shellcheck disable=SC1090
  source "$CLIENT_ENV"
  # shellcheck disable=SC1090
  source "$SERVER_ENV"
  XHTTP_PORT="${XHTTP_PORT_OVERRIDE:-${PORT:-$XHTTP_PORT}}"
  REALITY_TARGET="${REALITY_TARGET_OVERRIDE:-${TARGET:-$REALITY_TARGET}}"
  REALITY_SNI="${REALITY_SNI_OVERRIDE:-${SNI:-$REALITY_SNI}}"
else
  echo "[2/8] Generating fresh VLESS / REALITY credentials..."
  VLESS_ID="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
  KEY_OUTPUT="$("$INSTALL_DIR/xray" x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" | awk -F': ' '/^PrivateKey:/{print $2; exit}')"
  REALITY_PASSWORD="$(printf '%s\n' "$KEY_OUTPUT" | awk -F': ' '/^(Password|Password \(PublicKey\)):/{print $2; exit}')"
  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PASSWORD:-}" ]]; then
    echo "Failed to parse x25519 key output:"
    printf '%s\n' "$KEY_OUTPUT"
    exit 1
  fi
  read -r REALITY_SHORT_ID XHTTP_TOKEN < <(python3 - <<'PY'
import secrets
print(secrets.token_hex(8), secrets.token_hex(8))
PY
)
  XHTTP_PATH="/api/v1/${XHTTP_TOKEN}"
fi

: "${VLESS_ID:?Missing VLESS_ID}"
: "${REALITY_PRIVATE_KEY:?Missing REALITY_PRIVATE_KEY}"
: "${REALITY_PASSWORD:?Missing REALITY_PASSWORD}"
: "${REALITY_SHORT_ID:?Missing REALITY_SHORT_ID}"
: "${XHTTP_PATH:?Missing XHTTP_PATH}"

PORT="$XHTTP_PORT"
TARGET="$REALITY_TARGET"
SNI="$REALITY_SNI"

echo "[3/8] Checking REALITY camouflage target..."
TARGET_HOST="${REALITY_TARGET%:*}"
timeout 12 "$INSTALL_DIR/xray" tls ping "$TARGET_HOST" >/tmp/xhttp-reality-tls-ping.log 2>&1 || {
  echo "Warning: xray tls ping to ${TARGET_HOST} did not complete successfully."
  echo "The server will still be configured; inspect /tmp/xhttp-reality-tls-ping.log if needed."
}

echo "[4/8] Writing stable XHTTP + REALITY server configuration..."
cat >"$CONFIG_DIR/server.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "xhttp-reality-in",
      "listen": "0.0.0.0",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_ID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "auto",
          "path": "${XHTTP_PATH}"
        },
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            "${REALITY_SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF
chmod 600 "$CONFIG_DIR/server.json"
python3 -m json.tool "$CONFIG_DIR/server.json" >/dev/null

echo "[5/8] Validating Xray configuration..."
"$INSTALL_DIR/xray" run -test -c "$CONFIG_DIR/server.json"

cat >"$CLIENT_ENV" <<EOF
PORT='${XHTTP_PORT}'
VLESS_ID='${VLESS_ID}'
REALITY_PASSWORD='${REALITY_PASSWORD}'
REALITY_SHORT_ID='${REALITY_SHORT_ID}'
SNI='${REALITY_SNI}'
XHTTP_PATH='${XHTTP_PATH}'
EOF
chmod 600 "$CLIENT_ENV"

cat >"$SERVER_ENV" <<EOF
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'
TARGET='${REALITY_TARGET}'
EOF
chmod 600 "$SERVER_ENV"

echo "[6/8] Installing systemd service..."
cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=XHTTP REALITY tunnel server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xray run -c ${CONFIG_DIR}/server.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF

if command -v sysctl >/dev/null 2>&1; then
  cat >/etc/sysctl.d/99-xhttp-reality-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
fi

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"
sleep 2

echo "[7/8] Firewall..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${XHTTP_PORT}/tcp"
  echo "UFW allows TCP ${XHTTP_PORT}."
else
  echo "UFW is not active. If your provider has a firewall/security group, allow TCP ${XHTTP_PORT} there."
fi

echo "[8/8] Verification..."
systemctl --no-pager --full status "${SERVICE_NAME}.service" | sed -n '1,14p' || true
echo
if command -v ss >/dev/null 2>&1; then
  ss -lntp "( sport = :${XHTTP_PORT} )" || true
else
  python3 - "$XHTTP_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(2)
try:
    rc = s.connect_ex(('127.0.0.1', port))
    print(f'127.0.0.1:{port} listening={rc == 0}')
finally:
    s.close()
PY
fi

echo
echo "============================================================"
echo "XHTTP + REALITY FOREIGN SERVER READY"
echo "Xray version : ${XRAY_VERSION}"
echo "Port         : ${XHTTP_PORT}/TCP"
echo "Target/SNI   : ${REALITY_TARGET} / ${REALITY_SNI}"
echo "VLESS ID     : ${VLESS_ID}"
echo "Password     : ${REALITY_PASSWORD}"
echo "Short ID     : ${REALITY_SHORT_ID}"
echo "XHTTP Path   : ${XHTTP_PATH}"
echo
echo "Client values saved in: ${CLIENT_ENV}"
echo "Server secret saved in: ${SERVER_ENV}"
echo "============================================================"

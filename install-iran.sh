#!/usr/bin/env bash
set -Eeuo pipefail

XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/xhttp-reality}"
CONFIG_DIR="${CONFIG_DIR:-/etc/xhttp-reality}"
SERVICE_NAME="xhttp-reality-client"
SOCKS_PORT="${SOCKS_PORT:-10818}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

FOREIGN_IP="${1:-${FOREIGN_IP:-}}"
PORT="${2:-${PORT:-}}"
VLESS_ID="${3:-${VLESS_ID:-}}"
REALITY_PASSWORD="${4:-${REALITY_PASSWORD:-}}"
REALITY_SHORT_ID="${5:-${REALITY_SHORT_ID:-}}"
SNI="${6:-${SNI:-}}"
XHTTP_PATH="${7:-${XHTTP_PATH:-}}"

[[ -n "$FOREIGN_IP" ]] || read -r -p "Foreign server IP/domain: " FOREIGN_IP
[[ -n "$PORT" ]] || read -r -p "Foreign XHTTP port [443]: " PORT
PORT="${PORT:-443}"
[[ -n "$VLESS_ID" ]] || read -r -p "VLESS ID: " VLESS_ID
[[ -n "$REALITY_PASSWORD" ]] || read -r -p "REALITY Password/PublicKey: " REALITY_PASSWORD
[[ -n "$REALITY_SHORT_ID" ]] || read -r -p "REALITY Short ID: " REALITY_SHORT_ID
[[ -n "$SNI" ]] || read -r -p "REALITY SNI: " SNI
[[ -n "$XHTTP_PATH" ]] || read -r -p "XHTTP Path: " XHTTP_PATH

if [[ -z "$FOREIGN_IP" || -z "$VLESS_ID" || -z "$REALITY_PASSWORD" || -z "$REALITY_SHORT_ID" || -z "$SNI" || -z "$XHTTP_PATH" ]]; then
  echo "All connection parameters are required."
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Invalid foreign port: $PORT"
  exit 1
fi
if ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || (( SOCKS_PORT < 1 || SOCKS_PORT > 65535 )); then
  echo "Invalid SOCKS_PORT: $SOCKS_PORT"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl unzip jq ca-certificates iproute2

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) ASSET="Xray-linux-64.zip" ;;
  arm64) ASSET="Xray-linux-arm64-v8a.zip" ;;
  *)
    echo "Unsupported architecture: $ARCH (supported: amd64, arm64)"
    exit 1
    ;;
esac

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ASSET}"
echo "[1/7] Installing Xray ${XRAY_VERSION}..."
curl -fL --retry 5 --retry-delay 2 --connect-timeout 15 "$URL" -o "$TMP/xray.zip"
unzip -q "$TMP/xray.zip" -d "$TMP/xray"
install -m 0755 "$TMP/xray/xray" "$INSTALL_DIR/xray"
XRAY_VERSION_LINE="$("$INSTALL_DIR/xray" version 2>/dev/null | sed -n '1p')"
echo "$XRAY_VERSION_LINE"

systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
if ss -lntH "( sport = :${SOCKS_PORT} )" 2>/dev/null | grep -q .; then
  echo
  echo "Local SOCKS port ${SOCKS_PORT} is already in use:"
  ss -lntp "( sport = :${SOCKS_PORT} )" || true
  echo
  echo "Use another local port, e.g.:"
  echo "  SOCKS_PORT=11818 ./install-iran.sh ..."
  exit 1
fi

echo "[2/7] Writing stable XHTTP + REALITY Iran/client configuration..."
cat >"$CONFIG_DIR/client.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "local-socks",
      "listen": "127.0.0.1",
      "port": ${SOCKS_PORT},
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "xhttp-reality-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${FOREIGN_IP}",
            "port": ${PORT},
            "users": [
              {
                "id": "${VLESS_ID}",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "auto",
          "path": "${XHTTP_PATH}"
        },
        "realitySettings": {
          "serverName": "${SNI}",
          "fingerprint": "chrome",
          "publicKey": "${REALITY_PASSWORD}",
          "shortId": "${REALITY_SHORT_ID}"
        }
      },
      "mux": {
        "enabled": true,
        "concurrency": -1,
        "xudpConcurrency": 16,
        "xudpProxyUDP443": "allow"
      }
    }
  ]
}
EOF
chmod 600 "$CONFIG_DIR/client.json"
jq empty "$CONFIG_DIR/client.json"

echo "[3/7] Validating Xray configuration..."
"$INSTALL_DIR/xray" run -test -c "$CONFIG_DIR/client.json"

cat >/root/xhttp-reality-iran.env <<EOF
FOREIGN_IP='${FOREIGN_IP}'
PORT='${PORT}'
VLESS_ID='${VLESS_ID}'
REALITY_PASSWORD='${REALITY_PASSWORD}'
REALITY_SHORT_ID='${REALITY_SHORT_ID}'
SNI='${SNI}'
XHTTP_PATH='${XHTTP_PATH}'
SOCKS_PORT='${SOCKS_PORT}'
EOF
chmod 600 /root/xhttp-reality-iran.env

echo "[4/7] Installing systemd service..."
cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=XHTTP REALITY tunnel client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xray run -c ${CONFIG_DIR}/client.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/sysctl.d/99-xhttp-reality-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"
sleep 2

echo "[5/7] Checking local SOCKS listener..."
if ! ss -lntH "( sport = :${SOCKS_PORT} )" | grep -q .; then
  echo "SOCKS listener did not start."
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager || true
  exit 1
fi

echo "[6/7] End-to-end tunnel test..."
TEST_OK=0
for URL_TEST in "https://icanhazip.com" "https://www.gstatic.com/generate_204"; do
  if curl -fsS --max-time 20 --connect-timeout 8 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" "$URL_TEST" >/tmp/xhttp-reality-test.out; then
    TEST_OK=1
    break
  fi
done

echo "[7/7] Verification..."
systemctl --no-pager --full status "${SERVICE_NAME}.service" | sed -n '1,14p' || true
echo
ss -lntp "( sport = :${SOCKS_PORT} )" || true
echo

if [[ "$TEST_OK" -eq 1 ]]; then
  echo "Tunnel test: OK"
  cat /tmp/xhttp-reality-test.out || true
else
  echo "Tunnel test: FAILED"
  echo "Debug:"
  echo "  journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
  echo "  nc -vz ${FOREIGN_IP} ${PORT}"
  echo "  curl -v --socks5-hostname 127.0.0.1:${SOCKS_PORT} https://icanhazip.com"
fi

echo
echo "============================================================"
echo "XHTTP + REALITY IRAN CLIENT READY"
echo "Xray version : ${XRAY_VERSION}"
echo "Local SOCKS  : 127.0.0.1:${SOCKS_PORT}"
echo "Foreign      : ${FOREIGN_IP}:${PORT}/TCP"
echo "UDP mode     : XUDP (UDP/443 allowed)"
echo "Service      : ${SERVICE_NAME}.service"
echo "Credentials  : /root/xhttp-reality-iran.env"
echo "============================================================"

[[ "$TEST_OK" -eq 1 ]]

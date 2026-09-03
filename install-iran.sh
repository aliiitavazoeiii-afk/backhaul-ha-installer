#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="${MIERU_VERSION:-3.36.0}"
PORT_START="${PORT_START:-20000}"
PORT_END="${PORT_END:-20007}"
PORT_RANGE="${PORT_START}-${PORT_END}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
RPC_PORT="${RPC_PORT:-10809}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo -i"
  exit 1
fi

SERVER_IP="${1:-}"
MIERU_USER="${2:-}"
MIERU_PASSWORD="${3:-}"

if [[ -z "$SERVER_IP" ]]; then
  read -r -p "Foreign server IPv4/IPv6: " SERVER_IP
fi
if [[ -z "$MIERU_USER" ]]; then
  read -r -p "Mieru username: " MIERU_USER
fi
if [[ -z "$MIERU_PASSWORD" ]]; then
  read -r -s -p "Mieru password: " MIERU_PASSWORD
  echo
fi

if [[ -z "$SERVER_IP" || -z "$MIERU_USER" || -z "$MIERU_PASSWORD" ]]; then
  echo "Server IP, username and password are required."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates chrony jq

systemctl enable --now chrony >/dev/null 2>&1 || true
timedatectl set-ntp true >/dev/null 2>&1 || true

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *)
    echo "Unsupported architecture: $ARCH (expected amd64 or arm64)"
    exit 1
    ;;
esac

PKG="/tmp/mieru_${VERSION}_${ARCH}.deb"
URL="https://github.com/enfein/mieru/releases/download/v${VERSION}/mieru_${VERSION}_${ARCH}.deb"

echo "[1/8] Downloading mieru ${VERSION} (${ARCH})..."
curl -fL --retry 5 --retry-delay 2 --connect-timeout 15 -o "$PKG" "$URL"
dpkg -i "$PKG" || apt-get -f install -y
rm -f "$PKG"

echo "[2/8] Enabling conservative TCP BBR..."
modprobe tcp_bbr >/dev/null 2>&1 || true
cat >/etc/sysctl.d/99-mieru-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1 || true

echo "[3/8] Checking local ports..."
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${SOCKS_PORT}$"; then
  echo "Local SOCKS port ${SOCKS_PORT} is already in use."
  echo "Re-run with e.g. SOCKS_PORT=11808 ./install-iran.sh ..."
  exit 1
fi
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${RPC_PORT}$"; then
  echo "Local RPC port ${RPC_PORT} is already in use."
  echo "Re-run with e.g. RPC_PORT=11809 ./install-iran.sh ..."
  exit 1
fi

echo "[4/8] Writing client configuration..."
mkdir -p /root/.config/mieru
cat >/root/mieru-client-config.json <<EOF
{
  "profiles": [
    {
      "profileName": "default",
      "user": {
        "name": "${MIERU_USER}",
        "password": "${MIERU_PASSWORD}"
      },
      "servers": [
        {
          "ipAddress": "${SERVER_IP}",
          "portBindings": [
            {
              "portRange": "${PORT_RANGE}",
              "protocol": "TCP"
            }
          ]
        }
      ],
      "mtu": 1400,
      "multiplexing": {
        "level": "MULTIPLEXING_LOW"
      },
      "handshakeMode": "HANDSHAKE_STANDARD",
      "trafficPattern": {
        "unlockAll": false,
        "tcpFragment": {
          "enable": true,
          "maxSleepMs": 3
        },
        "nonce": {
          "type": "NONCE_TYPE_PRINTABLE",
          "minLen": 6,
          "maxLen": 10
        },
        "padding": {
          "maxMiddlePaddingLen": 48,
          "maxEndPaddingLen": 96
        },
        "lowEntropy": {
          "mode": "LOW_ENTROPY_MODE_48",
          "maskRotation": "LOW_ENTROPY_MASK_ROTATE_RIGHT_7"
        }
      }
    }
  ],
  "activeProfile": "default",
  "rpcPort": ${RPC_PORT},
  "socks5Port": ${SOCKS_PORT},
  "loggingLevel": "INFO",
  "socks5ListenLAN": false
}
EOF
chmod 600 /root/mieru-client-config.json
jq empty /root/mieru-client-config.json

echo "[5/8] Applying configuration..."
mieru stop >/dev/null 2>&1 || true
mieru apply config /root/mieru-client-config.json

echo "[6/8] Installing persistent systemd service..."
cat >/etc/systemd/system/mieru-client.service <<EOF
[Unit]
Description=Mieru anti-DPI client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=/root
ExecStart=/usr/bin/mieru run
Restart=always
RestartSec=3
Nice=-5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mieru-client
sleep 3

echo "[7/8] Installing 3-strike end-to-end watchdog..."
cat >/usr/local/sbin/mieru-watchdog.sh <<EOF
#!/usr/bin/env bash
set -u
STATE=/run/mieru-watchdog.fail
SOCKS=127.0.0.1:${SOCKS_PORT}

ok=0
curl -fsS --max-time 8 --connect-timeout 4 --socks5-hostname "\$SOCKS" \
  -o /dev/null https://www.cloudflare.com/cdn-cgi/trace && ok=1
if [[ "\$ok" -eq 0 ]]; then
  curl -fsS --max-time 8 --connect-timeout 4 --socks5-hostname "\$SOCKS" \
    -o /dev/null https://www.gstatic.com/generate_204 && ok=1
fi

if [[ "\$ok" -eq 1 ]]; then
  rm -f "\$STATE"
  exit 0
fi

n=0
[[ -f "\$STATE" ]] && n=\$(cat "\$STATE" 2>/dev/null || echo 0)
n=\$((n+1))
echo "\$n" > "\$STATE"

if (( n >= 3 )); then
  systemctl restart mieru-client
  rm -f "\$STATE"
fi
EOF
chmod 750 /usr/local/sbin/mieru-watchdog.sh

cat >/etc/systemd/system/mieru-watchdog.service <<'EOF'
[Unit]
Description=Mieru end-to-end tunnel watchdog
After=mieru-client.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mieru-watchdog.sh
EOF

cat >/etc/systemd/system/mieru-watchdog.timer <<'EOF'
[Unit]
Description=Periodic Mieru tunnel health check

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now mieru-watchdog.timer

echo "[8/8] Verification..."
echo
systemctl --no-pager --full status mieru-client | sed -n '1,12p' || true
echo
echo "Effective traffic pattern:"
mieru describe effective-traffic-pattern || true
echo
echo "Testing SOCKS end-to-end..."
if curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" https://icanhazip.com; then
  echo
  echo "Tunnel test: OK"
else
  echo
  echo "Tunnel test failed. Run:"
  echo "  journalctl -u mieru-client -n 100 --no-pager"
  echo "  mieru get metrics"
  echo "  nc -vz ${SERVER_IP} ${PORT_START}"
fi

echo
echo "======================================================="
echo "IRAN CLIENT READY"
echo "Local SOCKS5 : 127.0.0.1:${SOCKS_PORT}"
echo "Foreign      : ${SERVER_IP}:${PORT_RANGE}/TCP"
echo "Xray outbound should point to 127.0.0.1:${SOCKS_PORT}"
echo "======================================================="

#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="${MIERU_VERSION:-3.36.0}"
PORT_START="${PORT_START:-20000}"
PORT_END="${PORT_END:-20007}"
PORT_RANGE="${PORT_START}-${PORT_END}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo -i"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl ca-certificates openssl chrony jq

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

PKG="/tmp/mita_${VERSION}_${ARCH}.deb"
URL="https://github.com/enfein/mieru/releases/download/v${VERSION}/mita_${VERSION}_${ARCH}.deb"

echo "[1/7] Downloading mita ${VERSION} (${ARCH})..."
curl -fL --retry 5 --retry-delay 2 --connect-timeout 15 -o "$PKG" "$URL"
dpkg -i "$PKG" || apt-get -f install -y
rm -f "$PKG"

echo "[2/7] Enabling conservative TCP BBR..."
modprobe tcp_bbr >/dev/null 2>&1 || true
cat >/etc/sysctl.d/99-mieru-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1 || true

MIERU_USER="${MIERU_USER:-m$(openssl rand -hex 4)}"
MIERU_PASSWORD="${MIERU_PASSWORD:-$(openssl rand -hex 24)}"

echo "[3/7] Writing Mieru server configuration..."
cat >/root/mieru-server-config.json <<EOF
{
  "portBindings": [
    {
      "portRange": "${PORT_RANGE}",
      "protocol": "TCP"
    }
  ],
  "users": [
    {
      "name": "${MIERU_USER}",
      "password": "${MIERU_PASSWORD}"
    }
  ],
  "loggingLevel": "INFO",
  "mtu": 1400,
  "advancedSettings": {
    "userHintIsMandatory": true
  },
  "trafficPattern": {
    "unlockAll": false,
    "tcpFragment": {
      "enable": false,
      "maxSleepMs": 0
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
      "maskRotation": "LOW_ENTROPY_MASK_ROTATE_LEFT_11"
    }
  }
}
EOF
chmod 600 /root/mieru-server-config.json

jq empty /root/mieru-server-config.json

echo "[4/7] Starting mita daemon and applying config..."
systemctl enable --now mita
sleep 1
mita apply config /root/mieru-server-config.json
mita stop >/dev/null 2>&1 || true
sleep 1
mita start
sleep 2

echo "[5/7] Firewall handling..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT_START}:${PORT_END}/tcp"
  echo "UFW opened TCP ${PORT_START}:${PORT_END}"
else
  echo "UFW is not active. Make sure your provider/firewall allows TCP ${PORT_START}-${PORT_END}."
fi

echo "[6/7] Installing lightweight service watchdog..."
cat >/usr/local/sbin/mita-watchdog.sh <<'EOF'
#!/usr/bin/env bash
set -u
if ! mita status 2>/dev/null | grep -q '"RUNNING"'; then
  mita start >/dev/null 2>&1 || true
fi
EOF
chmod 750 /usr/local/sbin/mita-watchdog.sh

cat >/etc/systemd/system/mita-watchdog.service <<'EOF'
[Unit]
Description=Check Mita proxy state

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mita-watchdog.sh
EOF

cat >/etc/systemd/system/mita-watchdog.timer <<'EOF'
[Unit]
Description=Periodic Mita proxy state check

[Timer]
OnBootSec=90s
OnUnitActiveSec=120s
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now mita-watchdog.timer

cat >/root/mieru-credentials.txt <<EOF
SERVER_PORT_RANGE=${PORT_RANGE}
MIERU_USER=${MIERU_USER}
MIERU_PASSWORD=${MIERU_PASSWORD}
EOF
chmod 600 /root/mieru-credentials.txt

echo "[7/7] Verification..."
echo
mita status || true
echo
echo "Effective traffic pattern:"
mita describe effective-traffic-pattern || true
echo
echo "======================================================="
echo "FOREIGN SERVER READY"
echo "TCP port range : ${PORT_RANGE}"
echo "Username       : ${MIERU_USER}"
echo "Password       : ${MIERU_PASSWORD}"
echo "Credentials    : /root/mieru-credentials.txt"
echo "======================================================="

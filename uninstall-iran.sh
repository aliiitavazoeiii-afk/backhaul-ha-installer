#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo -i"
  exit 1
fi

echo "[1/5] Stopping Mieru client/watchdog..."
systemctl disable --now mieru-watchdog.timer 2>/dev/null || true
systemctl disable --now mieru-watchdog.service 2>/dev/null || true
systemctl disable --now mieru-client.service 2>/dev/null || true
mieru stop >/dev/null 2>&1 || true
pkill -9 mieru 2>/dev/null || true

echo "[2/5] Removing Mieru systemd files..."
rm -f /etc/systemd/system/mieru-client.service
rm -f /etc/systemd/system/mieru-watchdog.service
rm -f /etc/systemd/system/mieru-watchdog.timer
rm -f /usr/local/sbin/mieru-watchdog.sh
rm -f /run/mieru-watchdog.fail
systemctl daemon-reload
systemctl reset-failed || true

echo "[3/5] Removing client config/state..."
rm -rf /root/.config/mieru
rm -f /root/mieru-client-config.json
rm -f /root/mieru-client-config.new.json

echo "[4/5] Removing installed Mieru package/binaries..."
if dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -qx 'mieru'; then
  apt-get purge -y mieru || true
fi
rm -f /usr/bin/mieru /usr/local/bin/mieru

echo "[5/5] Verification..."
if ss -lntp 2>/dev/null | grep -q ':10808'; then
  echo "WARNING: TCP 10808 is still in use by another process:"
  ss -lntp | grep ':10808' || true
else
  echo "TCP 10808 is free."
fi

if systemctl is-active --quiet x-ui 2>/dev/null; then
  echo "x-ui is still ACTIVE (untouched)."
else
  echo "x-ui was not modified by this script. Current state is not active or service is absent."
fi

echo "Mieru Iran uninstall complete."

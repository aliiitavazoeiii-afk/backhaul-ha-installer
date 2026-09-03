#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo -i"
  exit 1
fi

echo "[1/5] Stopping Mita/watchdog..."
systemctl disable --now mita-watchdog.timer 2>/dev/null || true
systemctl disable --now mita-watchdog.service 2>/dev/null || true
systemctl disable --now mita.service 2>/dev/null || true
mita stop >/dev/null 2>&1 || true
pkill -9 mita 2>/dev/null || true

echo "[2/5] Removing watchdog/systemd leftovers..."
rm -f /etc/systemd/system/mita-watchdog.service
rm -f /etc/systemd/system/mita-watchdog.timer
rm -f /usr/local/sbin/mita-watchdog.sh
systemctl daemon-reload
systemctl reset-failed || true

echo "[3/5] Removing Mita config/credentials..."
rm -f /root/mieru-server-config.json
rm -f /root/mieru-credentials.txt
rm -rf /root/.config/mita

echo "[4/5] Removing installed Mita/Mieru package/binaries..."
for pkg in mita mieru; do
  if dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -qx "$pkg"; then
    apt-get purge -y "$pkg" || true
  fi
done
rm -f /usr/bin/mita /usr/local/bin/mita

echo "[5/5] Verification..."
if ss -lntp 2>/dev/null | grep -Eq ':2000[0-7]'; then
  echo "WARNING: one or more TCP 20000-20007 ports are still in use:"
  ss -lntp | grep -E ':2000[0-7]' || true
else
  echo "TCP 20000-20007 are free."
fi

echo "Mieru foreign uninstall complete."

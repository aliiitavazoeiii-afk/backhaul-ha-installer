#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

echo "[1/6] Stopping dual controller..."
systemctl disable --now xhttp-dual-controller.service 2>/dev/null || true

if [[ -x /usr/local/bin/xhttp-dual && -f /etc/xhttp-dual/config.json ]]; then
  echo "[2/6] Removing managed x-ui routing/outbounds..."
  /usr/local/bin/xhttp-dual remove-managed || {
    echo "WARNING: managed x-ui cleanup failed; preserving tunnel files for safety."
    echo "Inspect: journalctl -u x-ui -n 100 --no-pager"
    exit 1
  }
else
  echo "[2/6] No complete controller/config; skipping x-ui cleanup."
fi

echo "[3/6] Stopping dual tunnel services..."
systemctl disable --now xhttp-dual-f1.service xhttp-dual-f2.service 2>/dev/null || true
systemctl stop xhttp-dual-f1.service xhttp-dual-f2.service 2>/dev/null || true

# Partial installs can leave orphaned Xray processes after unit removal.
pkill -f '/opt/xhttp-dual/xray' 2>/dev/null || true
sleep 1

rm -f /etc/systemd/system/xhttp-dual-controller.service
rm -f /etc/systemd/system/xhttp-dual-f1.service
rm -f /etc/systemd/system/xhttp-dual-f2.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "[4/6] Removing dual project files..."
rm -f /usr/local/bin/xhttp-dual
rm -f /usr/local/bin/xhttp-dual-replace
rm -rf /opt/xhttp-dual
rm -rf /etc/xhttp-dual
rm -f /etc/sysctl.d/99-xhttp-dual-bbr.conf
sysctl --system >/dev/null 2>&1 || true

echo "[5/6] Preserving safety backups..."
mkdir -p /var/lib/xhttp-dual
cat >/var/lib/xhttp-dual/UNINSTALLED.txt <<EOF
Uninstalled at $(date -Is)
Backups in /var/lib/xhttp-dual/backups are intentionally preserved.
Delete /var/lib/xhttp-dual manually only after you are sure rollback is unnecessary.
EOF

echo "[6/6] Verification..."
if ss -lntp | grep -E ':(11818|11819)\b'; then
  echo "WARNING: a process is still using a dual SOCKS port."
  exit 1
else
  echo "Dual SOCKS ports are free."
fi
systemctl is-active x-ui >/dev/null && echo "x-ui: active" || echo "WARNING: x-ui is not active"

echo
echo "XHTTP Dual Sticky Failover removed."
echo "Existing single XHTTP / Mieru / FRP services were not touched."
echo "Safety backups kept in /var/lib/xhttp-dual/backups"

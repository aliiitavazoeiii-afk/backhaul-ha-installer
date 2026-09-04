#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

echo "[1/5] Stopping dual controller..."
systemctl disable --now xhttp-dual-controller.service 2>/dev/null || true

if [[ -x /usr/local/bin/xhttp-dual && -f /etc/xhttp-dual/config.json ]]; then
  echo "[2/5] Removing only managed x-ui routing/outbounds (with rollback support)..."
  /usr/local/bin/xhttp-dual remove-managed || {
    echo "WARNING: managed x-ui cleanup failed. Tunnel services will NOT be removed automatically."
    echo "Fix the x-ui issue or inspect: journalctl -u x-ui -n 100 --no-pager"
    exit 1
  }
else
  echo "[2/5] Controller/config not found; skipping x-ui managed cleanup."
fi

echo "[3/5] Stopping dual XHTTP tunnel services..."
systemctl disable --now xhttp-dual-f1.service xhttp-dual-f2.service 2>/dev/null || true
rm -f /etc/systemd/system/xhttp-dual-controller.service
rm -f /etc/systemd/system/xhttp-dual-f1.service
rm -f /etc/systemd/system/xhttp-dual-f2.service
systemctl daemon-reload
systemctl reset-failed

echo "[4/5] Removing dual project files..."
rm -f /usr/local/bin/xhttp-dual
rm -rf /opt/xhttp-dual
rm -rf /etc/xhttp-dual
rm -f /etc/sysctl.d/99-xhttp-dual-bbr.conf
sysctl --system >/dev/null 2>&1 || true

mkdir -p /var/lib/xhttp-dual
cat >/var/lib/xhttp-dual/UNINSTALLED.txt <<EOF
Uninstalled at $(date -Is)
Backups in /var/lib/xhttp-dual/backups are intentionally preserved.
Delete /var/lib/xhttp-dual manually only after you are sure rollback is unnecessary.
EOF

echo "[5/5] Verification..."
ss -lntp | grep -E ':(11818|11819)\b' || echo "Dual SOCKS ports are free."
systemctl is-active x-ui >/dev/null && echo "x-ui: active" || echo "WARNING: x-ui is not active"

echo
echo "XHTTP Dual Sticky Failover removed."
echo "Existing single XHTTP / Mieru / FRP services were not touched."
echo "Safety backups kept in /var/lib/xhttp-dual/backups"

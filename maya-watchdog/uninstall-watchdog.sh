#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
systemctl disable --now maya-watchdog.service 2>/dev/null || true
rm -f /etc/systemd/system/maya-watchdog.service
systemctl daemon-reload
rm -f /usr/local/bin/maya-watchdog
rm -rf /opt/maya-watchdog /etc/maya-watchdog /var/lib/maya-watchdog
echo "MAYA WATCHDOG REMOVED"

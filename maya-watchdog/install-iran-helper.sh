#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/maya-watchdog/maya-watchdog/xhttp-dual-replace-ip"
curl -fsSL "$URL" -o /usr/local/bin/xhttp-dual-replace-ip
chmod 0755 /usr/local/bin/xhttp-dual-replace-ip
/usr/local/bin/xhttp-dual-replace-ip 2>/dev/null || true
echo "IRAN HELPER INSTALLED"

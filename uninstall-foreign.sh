#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="xhttp-reality-server"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/xhttp-reality}"
CONFIG_DIR="${CONFIG_DIR:-/etc/xhttp-reality}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

echo "[1/4] Stopping standalone XHTTP server..."
systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl reset-failed

echo "[2/4] Removing server config and tunnel credentials..."
rm -f "${CONFIG_DIR}/server.json"
rm -f /root/xhttp-reality-client.env
rm -f /root/xhttp-reality-server-secrets.env

echo "[3/4] Removing standalone Xray binary..."
if ! systemctl cat xhttp-reality-client.service >/dev/null 2>&1; then
  rm -rf "$INSTALL_DIR"
fi
rmdir "$CONFIG_DIR" 2>/dev/null || true

echo "[4/4] Cleaning project sysctl file..."
rm -f /etc/sysctl.d/99-xhttp-reality-bbr.conf
sysctl --system >/dev/null 2>&1 || true

echo
echo "XHTTP REALITY foreign server removed."
echo "Firewall rules are intentionally left unchanged."

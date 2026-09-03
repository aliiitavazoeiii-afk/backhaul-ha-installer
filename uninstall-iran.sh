#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="xhttp-reality-client"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/xhttp-reality}"
CONFIG_DIR="${CONFIG_DIR:-/etc/xhttp-reality}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

echo "[1/4] Stopping only the standalone XHTTP client..."
systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl reset-failed

echo "[2/4] Removing standalone client config/credentials..."
rm -f "${CONFIG_DIR}/client.json"
rm -f /root/xhttp-reality-iran.env

echo "[3/4] Removing binary only if no XHTTP server service exists locally..."
if ! systemctl cat xhttp-reality-server.service >/dev/null 2>&1; then
  rm -rf "$INSTALL_DIR"
fi
rmdir "$CONFIG_DIR" 2>/dev/null || true

echo "[4/4] Cleaning project sysctl file..."
rm -f /etc/sysctl.d/99-xhttp-reality-bbr.conf
sysctl --system >/dev/null 2>&1 || true

echo
echo "XHTTP REALITY Iran client removed."
echo "x-ui / Xray managed by x-ui was NOT touched."

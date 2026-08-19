#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root"; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
if [[ -z "$ROLE" ]]; then
  read -r -p "Role to remove [iran/foreign]: " ROLE
fi
case "$ROLE" in
  iran)
    systemctl disable --now backhaul backhaul-wss 2>/dev/null || true
    systemctl disable --now haproxy 2>/dev/null || true
    rm -f /etc/systemd/system/backhaul.service /etc/systemd/system/backhaul-wss.service
    rm -rf /etc/backhaul /etc/backhaul-ha
    rm -f /usr/local/bin/tunnelctl
    echo "Tunnel removed. HAProxy package, UFW rules, certificates and x-ui were intentionally left intact."
    ;;
  foreign)
    systemctl disable --now backhaul backhaul-wss backhaul-health 2>/dev/null || true
    rm -f /etc/systemd/system/backhaul.service /etc/systemd/system/backhaul-wss.service /etc/systemd/system/backhaul-health.service
    rm -rf /etc/backhaul /etc/backhaul-ha /opt/backhaul-health
    rm -f /usr/local/bin/tunnelctl
    echo "Tunnel removed. x-ui and its database were intentionally left intact."
    ;;
  *) echo "Invalid role"; exit 2 ;;
esac
systemctl daemon-reload
systemctl reset-failed || true

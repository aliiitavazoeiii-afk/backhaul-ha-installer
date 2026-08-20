#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }

echo "[i] Resetting Backhaul HA lab state..."

services=(
  backhaul
  backhaul-wss
  backhaul-tcp
  backhaul-health
  backhaul-diag-iperf
  haproxy
)

for svc in "${services[@]}"; do
  systemctl disable --now "$svc" >/dev/null 2>&1 || true
done

rm -f \
  /etc/systemd/system/backhaul.service \
  /etc/systemd/system/backhaul-wss.service \
  /etc/systemd/system/backhaul-tcp.service \
  /etc/systemd/system/backhaul-health.service \
  /etc/systemd/system/backhaul-diag-iperf.service

rm -rf \
  /etc/backhaul \
  /etc/backhaul-ha \
  /opt/backhaul-health

rm -f \
  /usr/local/bin/backhaul \
  /usr/local/bin/tunnelctl \
  /usr/local/bin/tunnel-diagnose \
  /root/backhaul-ha-secrets.env

# HAProxy is dedicated to the Iran-side test topology in this project.
# Remove its generated configuration but leave the package installed.
rm -f /etc/haproxy/haproxy.cfg

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

# Do not reset UFW here: the installer owns and rebuilds its firewall policy.
# Do not remove Certbot certificates or x-ui databases to avoid destructive
# cleanup outside the tunnel itself.

echo "[+] Tunnel lab state removed."
echo "[i] Preserved: x-ui/database, Certbot certificates, installed packages."
echo "[i] The next installer run will rebuild the project firewall/configuration."

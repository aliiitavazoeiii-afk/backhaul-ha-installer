#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root.' >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/backhaul-cleanup-backup-$TS"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"

echo "[i] Backup: $BACKUP"

backup_path() {
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  mkdir -p "$BACKUP$(dirname "$p")"
  cp -a -- "$p" "$BACKUP$p" 2>/dev/null || true
}

for p in \
  /etc/haproxy/haproxy.cfg \
  /etc/dual-backhaul \
  /etc/dual-backhaul-ha \
  /etc/dual-user-sync \
  /etc/dual-wss-stealth \
  /etc/backhaul \
  /etc/backhaul-ha \
  /opt/dual-backhaul-health \
  /opt/dual-stealth-health \
  /opt/backhaul-health \
  /root/dual-backhaul-foreign-a.env \
  /root/dual-backhaul-foreign-b.env \
  /root/dual-stealth-a.env \
  /root/dual-stealth-b.env \
  /root/backhaul-ha-secrets.env; do
  backup_path "$p"
done

# Stop all known tunnel/control-plane units. x-ui/xray are intentionally untouched.
units=(
  dual-bh-a-wss dual-bh-a-mux dual-bh-a-tcp
  dual-bh-b-wss dual-bh-b-mux dual-bh-b-tcp
  dual-bh-wss dual-bh-mux dual-bh-tcp dual-bh-health
  dual-user-sync.service dual-user-sync.timer
  dual-stealth-a-server dual-stealth-b-server dual-stealth-client dual-stealth-health dual-stealth-tls
  backhaul backhaul-wss backhaul-tcp backhaul-tcptls
  backhaul-health backhaul-wss-tls backhaul-wss-ab
)
for u in "${units[@]}"; do
  systemctl disable --now "$u" >/dev/null 2>&1 || true
done

# Stop HAProxy only when its active config belongs to this tunnel family.
if [[ -f /etc/haproxy/haproxy.cfg ]] && grep -Eq 'backend vpn_users|slot_a_transports|backhaul_wss|control_a_wss|foreign_a|stealth_control_a' /etc/haproxy/haproxy.cfg; then
  systemctl disable --now haproxy >/dev/null 2>&1 || true
  rm -f /etc/haproxy/haproxy.cfg
fi

# Remove only tunnel-owned nginx/stunnel configuration. Do not purge packages.
rm -f \
  /etc/nginx/sites-enabled/backhaul-decoy \
  /etc/nginx/sites-available/backhaul-decoy \
  /etc/nginx/sites-enabled/backhaul-decoy-ab-http \
  /etc/nginx/sites-available/backhaul-decoy-ab-http \
  /etc/nginx/sites-enabled/dual-wss-stealth \
  /etc/nginx/sites-available/dual-wss-stealth \
  /etc/stunnel/backhaul-wss-split.conf \
  /etc/stunnel/backhaul-wss-ab.conf \
  /etc/letsencrypt/renewal-hooks/deploy/backhaul-wss-split-tls \
  /etc/letsencrypt/renewal-hooks/deploy/dual-wss-stealth
rm -rf /var/www/backhaul-decoy /var/www/dual-stealth-decoy

# Remove tunnel state/config/binaries. Certificates and X-UI are preserved.
rm -rf \
  /etc/dual-backhaul \
  /etc/dual-backhaul-ha \
  /etc/dual-user-sync \
  /etc/dual-wss-stealth \
  /etc/backhaul \
  /etc/backhaul-ha \
  /opt/dual-backhaul-health \
  /opt/dual-stealth-health \
  /opt/backhaul-health \
  /usr/local/lib/backhaul-ha

rm -f \
  /usr/local/bin/backhaul-dual \
  /usr/local/bin/backhaul \
  /usr/local/bin/backhaul-stealth \
  /usr/local/bin/dual-diagnose \
  /usr/local/bin/dual-usersync \
  /usr/local/bin/tunnelctl \
  /usr/local/bin/tunnel-diagnose \
  /usr/local/bin/stealthctl

rm -f \
  /etc/systemd/system/dual-bh-*.service \
  /etc/systemd/system/dual-user-sync.service \
  /etc/systemd/system/dual-user-sync.timer \
  /etc/systemd/system/dual-stealth-*.service \
  /etc/systemd/system/backhaul.service \
  /etc/systemd/system/backhaul-wss.service \
  /etc/systemd/system/backhaul-tcp.service \
  /etc/systemd/system/backhaul-tcptls.service \
  /etc/systemd/system/backhaul-health.service \
  /etc/systemd/system/backhaul-wss-tls.service \
  /etc/systemd/system/backhaul-wss-ab.service

rm -f \
  /root/dual-backhaul-foreign-a.env \
  /root/dual-backhaul-foreign-b.env \
  /root/dual-stealth-a.env \
  /root/dual-stealth-b.env \
  /root/backhaul-ha-secrets.env

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

# Reload nginx only if it remains installed and active; do not start it.
if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
fi

echo '[+] Tunnel project cleanup complete.'
echo "[+] Preserved: x-ui/xray, SSH, Let's Encrypt certificates, unrelated firewall rules/packages."
echo "[+] Backup saved at: $BACKUP"
echo '[i] Verify with:'
echo "    systemctl list-units --all | grep -E 'dual-bh|dual-stealth|backhaul|dual-user-sync|haproxy' || true"
echo "    ss -lntp | grep -E ':(8443|8543|10443|10444|11443|11444|12443|12444|20443|20444|21443|21444|22443|22444|15001|15002|3080|3081|3180|3181)\\b' || true"

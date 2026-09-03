#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE="/root/backhaul-ha-secrets.env"
BACKUP_PTR="/etc/backhaul-ha/phase3-backup-path"
PHASE3_MARKER="/etc/backhaul-ha/phase3-tcptls"
STUNNEL_CONF="/etc/stunnel/backhaul-tcpmux.conf"
STUNNEL_UNIT="/etc/systemd/system/backhaul-tcptls.service"
BACKHAUL_DROPIN="/etc/systemd/system/backhaul.service.d/phase3-tcptls.conf"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/backhaul-phase3-tcptls"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo "[x] Tunnel role not detected." >&2; exit 2; }
[[ -f "$BACKUP_PTR" ]] || { echo "[x] No Phase 3 backup pointer found." >&2; exit 3; }
BACKUP_ROOT="$(cat "$BACKUP_PTR")"
[[ -d "$BACKUP_ROOT" ]] || { echo "[x] Missing Phase 3 backup directory: $BACKUP_ROOT" >&2; exit 3; }

restore_path() {
  local p="$1"
  if [[ -e "$BACKUP_ROOT$p" || -L "$BACKUP_ROOT$p" ]]; then
    mkdir -p "$(dirname "$p")"
    rm -rf -- "$p"
    cp -a -- "$BACKUP_ROOT$p" "$p"
  elif grep -Fxq "$p" "$BACKUP_ROOT/.missing" 2>/dev/null; then
    rm -rf -- "$p"
  fi
}

systemctl stop backhaul.service 2>/dev/null || true
systemctl stop backhaul-tcptls.service 2>/dev/null || true

if [[ "$ROLE" == iran ]]; then
  restore_path /etc/backhaul/server.toml
  restore_path /etc/haproxy/haproxy.cfg
  restore_path "$BUNDLE"
  restore_path "$STUNNEL_CONF"
  restore_path "$STUNNEL_UNIT"
  restore_path "$BACKHAUL_DROPIN"
  restore_path "$RENEW_HOOK"

  FOREIGN_IP="$(sed -n "s/^FOREIGN_IP='\([^']*\)'$/\1/p" "$BUNDLE" | head -n1)"
  if command -v ufw >/dev/null 2>&1 && [[ -n "$FOREIGN_IP" ]]; then
    ufw allow from "$FOREIGN_IP" to any port 3080 proto tcp comment 'Backhaul TCPMux control' >/dev/null 2>&1 || true
  fi

  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null
else
  restore_path /etc/backhaul/client.toml
  restore_path "$BUNDLE"
  restore_path "$STUNNEL_CONF"
  restore_path "$STUNNEL_UNIT"
  restore_path "$BACKHAUL_DROPIN"
fi

systemctl daemon-reload
systemctl restart backhaul.service
if [[ "$ROLE" == iran ]]; then
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
fi

rm -f "$PHASE3_MARKER" "$BACKUP_PTR"

echo "[+] Phase 3 TCPMux TLS wrapper rolled back on role=$ROLE."

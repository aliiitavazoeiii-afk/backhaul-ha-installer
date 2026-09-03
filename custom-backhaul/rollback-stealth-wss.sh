#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_PTR="/etc/backhaul-ha/phase2-backup-path"
PHASE2_MARKER="/etc/backhaul-ha/phase2-stealth-wss"
NGINX_SITE="/etc/nginx/sites-available/backhaul-decoy"
NGINX_LINK="/etc/nginx/sites-enabled/backhaul-decoy"
NGINX_DEFAULT_LINK="/etc/nginx/sites-enabled/default"
DECOY_ROOT="/var/www/backhaul-decoy"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || { echo "[x] Tunnel role not detected." >&2; exit 2; }
[[ -f "$BACKUP_PTR" ]] || { echo "[x] No Phase 2 backup pointer found." >&2; exit 3; }
BACKUP_ROOT="$(cat "$BACKUP_PTR")"
[[ -d "$BACKUP_ROOT" ]] || { echo "[x] Phase 2 backup directory missing: $BACKUP_ROOT" >&2; exit 3; }

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

if [[ "$ROLE" == "iran" ]]; then
  restore_path /etc/backhaul/server-wss.toml
  restore_path /etc/haproxy/haproxy.cfg
  restore_path /root/backhaul-ha-secrets.env
  restore_path "$NGINX_SITE"
  restore_path "$NGINX_LINK"
  restore_path "$NGINX_DEFAULT_LINK"
  restore_path "$DECOY_ROOT"

  if command -v nginx >/dev/null 2>&1; then
    nginx -t
  fi
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null

  systemctl restart backhaul-wss
  if command -v nginx >/dev/null 2>&1; then
    nginx_active_before="$(sed -n 's/^nginx_active=//p' "$BACKUP_ROOT/.meta" | head -1)"
    if [[ "$nginx_active_before" == 1 ]]; then
      systemctl restart nginx
    else
      systemctl stop nginx 2>/dev/null || true
    fi
  fi
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
else
  restore_path /etc/backhaul/client-wss.toml
  restore_path /root/backhaul-ha-secrets.env
  systemctl restart backhaul-wss
fi

rm -f "$PHASE2_MARKER" "$BACKUP_PTR"

echo "[+] Phase 2 stealth WSS configuration rolled back on role=$ROLE"
if command -v tunnel-diagnose >/dev/null 2>&1; then
  echo
  tunnel-diagnose || true
fi

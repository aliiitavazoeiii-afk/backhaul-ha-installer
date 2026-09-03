#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=""
YES=0

usage() {
  cat <<'EOF'
Custom Backhaul v2 uninstaller

Usage:
  bash uninstall-final-v2.sh --role iran --yes
  bash uninstall-final-v2.sh --role foreign --yes

Removes the Backhaul HA/v2 stack, its service units, configs, secrets and
project backups. It intentionally does NOT purge apt packages, change UFW,
remove Let's Encrypt certificates, or uninstall 3x-ui/Xray.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[x] Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || { echo "[x] --role must be iran or foreign." >&2; exit 2; }
[[ "$YES" -eq 1 ]] || { echo "[x] Destructive operation. Re-run with --yes." >&2; exit 2; }

DETECTED="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
if [[ -n "$DETECTED" && "$DETECTED" != "$ROLE" ]]; then
  echo "[x] Requested role=$ROLE but installed role appears to be $DETECTED. Refusing." >&2
  exit 3
fi

echo "[i] Removing Custom Backhaul v2 stack on role=$ROLE ..."

# Stop/disable every project unit that is currently known to systemd.
mapfile -t units < <(systemctl list-unit-files --no-legend 2>/dev/null \
  | awk '$1 ~ /^backhaul.*\.(service|timer|path|socket)$/ {print $1}')
for u in "${units[@]:-}"; do
  [[ -n "$u" ]] || continue
  systemctl disable --now "$u" >/dev/null 2>&1 || true
done

# Explicit names cover stale/loaded units that may no longer appear in list-unit-files.
for u in \
  backhaul.service \
  backhaul-wss.service \
  backhaul-tcp.service \
  backhaul-health.service \
  backhaul-tcptls.service \
  backhaul-wss-tls.service \
  backhaul-wss-ab.service; do
  systemctl disable --now "$u" >/dev/null 2>&1 || true
done

if [[ "$ROLE" == "iran" ]]; then
  # Public ingress belonged to this stack on fresh-install nodes.
  systemctl disable --now haproxy.service >/dev/null 2>&1 || true

  rm -f \
    /etc/nginx/sites-enabled/backhaul-decoy \
    /etc/nginx/sites-available/backhaul-decoy \
    /etc/nginx/sites-enabled/backhaul-decoy-ab-http \
    /etc/nginx/sites-available/backhaul-decoy-ab-http \
    /etc/stunnel/backhaul-wss-split.conf \
    /etc/stunnel/backhaul-wss-ab.conf \
    /etc/letsencrypt/renewal-hooks/deploy/backhaul-wss-split-tls \
    /etc/letsencrypt/renewal-hooks/deploy/backhaul-phase3-tcptls
  rm -rf /var/www/backhaul-decoy

  # If nginx has no remaining enabled site, stop it; otherwise reload remaining config.
  if command -v nginx >/dev/null 2>&1; then
    if find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    else
      systemctl stop nginx >/dev/null 2>&1 || true
    fi
  fi
fi

# Phase 3 stunnel config exists on both roles.
rm -f /etc/stunnel/backhaul-tcpmux.conf

# Remove all project-owned systemd unit/drop-in files.
rm -f /etc/systemd/system/backhaul*.service /etc/systemd/system/backhaul*.timer \
      /etc/systemd/system/backhaul*.path /etc/systemd/system/backhaul*.socket
rm -rf /etc/systemd/system/backhaul.service.d

# Remove project config, binaries, diagnostics, secrets and rollback material.
rm -rf \
  /etc/backhaul \
  /etc/backhaul-ha \
  /usr/local/lib/backhaul-ha \
  /root/backhaul-ha-backups
rm -f \
  /usr/local/bin/backhaul \
  /usr/local/bin/tunnelctl \
  /usr/local/bin/tunnel-diagnose \
  /root/backhaul-ha-secrets.env

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

# Safety verification.
if [[ -e /usr/local/bin/backhaul || -d /etc/backhaul || -d /etc/backhaul-ha ]]; then
  echo "[x] Core Backhaul files still exist after uninstall." >&2
  exit 4
fi

active_left="$(systemctl --no-legend --state=active --type=service 2>/dev/null \
  | awk '$1 ~ /^backhaul.*\.service$/ {print $1}' | paste -sd, -)"
if [[ -n "$active_left" ]]; then
  echo "[x] Backhaul service(s) still active: $active_left" >&2
  exit 5
fi

echo "[+] Custom Backhaul v2 stack removed from role=$ROLE."
echo "[i] Left untouched intentionally: UFW rules, apt packages, Let's Encrypt certs, 3x-ui/Xray."

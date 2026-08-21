#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == "iran" ]] || { echo "[x] This cleanup runs on the Iran role only." >&2; exit 2; }
[[ -f /etc/backhaul-ha/phase2-split-tls ]] || { echo "[x] Final Phase 2 split-TLS marker missing; refusing to remove A/B fallback." >&2; exit 2; }

AB_UNIT="/etc/systemd/system/backhaul-wss-ab.service"
AB_CONF="/etc/stunnel/backhaul-wss-ab.conf"
AB_NGINX_SITE="/etc/nginx/sites-available/backhaul-decoy-ab-http"
AB_NGINX_LINK="/etc/nginx/sites-enabled/backhaul-decoy-ab-http"

# Stop by unit name unconditionally. systemctl can stop a loaded transient/stale
# unit even when list-unit-files no longer reports it.
systemctl stop backhaul-wss-ab.service 2>/dev/null || true
systemctl disable backhaul-wss-ab.service 2>/dev/null || true

rm -f "$AB_UNIT" "$AB_CONF" "$AB_NGINX_LINK" "$AB_NGINX_SITE"
systemctl daemon-reload
systemctl reset-failed backhaul-wss-ab.service 2>/dev/null || true

# Do not touch the production split-TLS services. Validate they are healthy.
systemctl is-active --quiet backhaul-wss-tls.service || { echo "[x] Production WSS TLS terminator is not active." >&2; exit 3; }
systemctl is-active --quiet nginx || { echo "[x] nginx is not active." >&2; exit 3; }
systemctl is-active --quiet backhaul-wss || { echo "[x] Backhaul WSMux is not active." >&2; exit 3; }
systemctl is-active --quiet haproxy || { echo "[x] HAProxy is not active." >&2; exit 3; }

if ss -lntp 2>/dev/null | grep -q '127\.0\.0\.1:9445'; then
  echo "[x] Temporary :9445 listener is still present after cleanup." >&2
  ss -lntp 2>/dev/null | grep '127\.0\.0\.1:9445' >&2 || true
  exit 4
fi

printf '[+] Temporary Phase 2 A/B service removed.\n'
printf '[+] Production split-TLS chain was left untouched.\n'

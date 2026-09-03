#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="/usr/local/lib/backhaul-ha"
STOCK_BIN="$BACKUP_DIR/backhaul-stock-v0.7.2"
MARKER="/etc/backhaul-ha/custom-v2"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || { echo "[x] Tunnel role not detected." >&2; exit 2; }
[[ -x "$STOCK_BIN" ]] || { echo "[x] Stock rollback binary missing: $STOCK_BIN" >&2; exit 3; }

if [[ -x /usr/local/bin/backhaul ]]; then
  install -m 0755 /usr/local/bin/backhaul "$BACKUP_DIR/backhaul-custom-v2-rollback-copy"
fi
install -m 0755 "$STOCK_BIN" /usr/local/bin/backhaul
rm -f "$MARKER"

systemctl restart backhaul backhaul-wss backhaul-tcp

echo "[+] Restored stock Backhaul v0.7.2 on role=$ROLE"
if command -v tunnel-diagnose >/dev/null 2>&1; then
  echo
  tunnel-diagnose || true
fi

#!/usr/bin/env bash
set -u

BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-dual-sticky-failover"
INSTALLER="/root/install-dual-iran.sh"
FIXER="/root/fix-xui-template.sh"
DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

curl -fsSL "$BASE_URL/install-dual-iran.sh" -o "$INSTALLER" || exit 1
chmod +x "$INSTALLER"

"$INSTALLER"
RC=$?
if [[ $RC -eq 0 ]]; then
  exit 0
fi

# Recovery path for newer/fresh 3x-ui databases where xrayTemplateConfig
# has not yet been persisted in the settings table.
if [[ -f /etc/xhttp-dual/config.json && -x /usr/local/bin/xhttp-dual && -f "$DB_PATH" ]]; then
  if ! sqlite3 "$DB_PATH" "SELECT 1 FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;" 2>/dev/null | grep -qx 1; then
    echo
    echo "Detected missing settings.xrayTemplateConfig; bootstrapping it and resuming install..."
    curl -fsSL "$BASE_URL/fix-xui-template.sh" -o "$FIXER" || exit "$RC"
    chmod +x "$FIXER"
    "$FIXER" || exit "$RC"
    /usr/local/bin/xhttp-dual sync || exit "$RC"
    systemctl daemon-reload
    systemctl enable --now xhttp-dual-controller.service || exit "$RC"
    sleep 2
    /usr/local/bin/xhttp-dual status
    echo
    echo "XHTTP DUAL STICKY FAILOVER READY"
    echo "Status : xhttp-dual status"
    echo "Replace: xhttp-dual-replace"
    exit 0
  fi
fi

exit "$RC"

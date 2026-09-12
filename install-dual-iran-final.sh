#!/usr/bin/env bash
set -u

PROJECT_REF="${PROJECT_REF:-xhttp-dual-sticky-failover}"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${PROJECT_REF}"
INSTALLER="/root/install-dual-iran.sh"
FIXER="/root/fix-xui-template.sh"
UPGRADER="/root/upgrade-dual-user-routing.sh"
LATENCY_UPGRADER="/root/upgrade-dual-latency-health.sh"
HARDENING_UPGRADER="/root/upgrade-dual-hardening.sh"
DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

finish_upgrade() {
  curl -fsSL "$BASE_URL/upgrade-dual-user-routing.sh" -o "$UPGRADER" || return 1
  chmod +x "$UPGRADER"
  PROJECT_REF="$PROJECT_REF" "$UPGRADER"
}

finish_latency_upgrade() {
  curl -fsSL "$BASE_URL/upgrade-dual-latency-health.sh" -o "$LATENCY_UPGRADER" || return 1
  chmod +x "$LATENCY_UPGRADER"
  PROJECT_REF="$PROJECT_REF" "$LATENCY_UPGRADER"
}

finish_hardening_upgrade() {
  curl -fsSL "$BASE_URL/upgrade-dual-hardening.sh" -o "$HARDENING_UPGRADER" || return 1
  chmod +x "$HARDENING_UPGRADER"
  PROJECT_REF="$PROJECT_REF" "$HARDENING_UPGRADER"
}

curl -fsSL "$BASE_URL/install-dual-iran.sh" -o "$INSTALLER" || exit 1
chmod +x "$INSTALLER"

PROJECT_REF="$PROJECT_REF" "$INSTALLER"
RC=$?
if [[ $RC -eq 0 ]]; then
  finish_upgrade || exit 1
  finish_latency_upgrade || exit 1
  finish_hardening_upgrade || exit 1
  echo
  echo "XHTTP DUAL STICKY FAILOVER V4 READY"
  echo "Status   : xhttp-dual status"
  echo "Diagnose : xhttp-dual diagnose"
  echo "Netcheck : xhttp-dual netcheck"
  echo "Replace  : xhttp-dual-replace"
  echo "Reset    : xhttp-dual-reset [all|f1|f2]"
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
    finish_upgrade || exit 1
    finish_latency_upgrade || exit 1
    finish_hardening_upgrade || exit 1
    echo
    echo "XHTTP DUAL STICKY FAILOVER V4 READY"
    echo "Status   : xhttp-dual status"
    echo "Diagnose : xhttp-dual diagnose"
    echo "Netcheck : xhttp-dual netcheck"
    echo "Replace  : xhttp-dual-replace"
    echo "Reset    : xhttp-dual-reset [all|f1|f2]"
    exit 0
  fi
fi

exit "$RC"

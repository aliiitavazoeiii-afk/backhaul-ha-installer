#!/usr/bin/env bash
set -Eeuo pipefail

BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-foreign-active-active/dual-foreign-active-active/user-sync"
SYNC="/usr/local/lib/dual-user-sync/dual_user_sync.py"
CFG="/etc/dual-user-sync/config.json"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root' >&2; exit 1; }
[[ -f "$CFG" ]] || { echo '[x] Existing user-sync config not found' >&2; exit 2; }

install -d -m 0755 /usr/local/lib/dual-user-sync
curl -fsSL "$BASE/dual_user_sync.py" -o "$SYNC"
chmod 0755 "$SYNC"
python3 -m py_compile "$SYNC"

echo '[i] Installed canonical user-sync implementation.'
python3 "$SYNC" --version

echo '[i] Checking A/B user state...'
dual-usersync check

echo '[i] Running synchronization using the current deletion safety mode...'
dual-usersync sync

systemctl daemon-reload
if systemctl cat dual-user-sync.timer >/dev/null 2>&1; then
  systemctl enable --now dual-user-sync.timer >/dev/null
  echo '[+] dual-user-sync.timer enabled.'
else
  echo '[!] Timer unit is missing; sync itself is repaired but periodic scheduling was not enabled.' >&2
fi

echo '[+] User-sync repair complete.'
dual-usersync check

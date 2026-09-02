#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] run as root' >&2; exit 1; }
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo "Usage: $0 {iran|foreign}" >&2; exit 2; }

BASE_INSTALL_COMMIT="846ae5852da71c0e43f8112d48b30f52977ad2b1"
MUX_UPGRADE_COMMIT="6b646630ac336f0c1b1c906d2a6f73e169b817e4"
BASE_INSTALL_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${BASE_INSTALL_COMMIT}/frp-classic443-hardened/install.sh"
MUX_UPGRADE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${MUX_UPGRADE_COMMIT}/frp-classic443-hardened/upgrade-mux-v4.sh"

echo "[+] Fresh Classic443 Mux-v4 install: role=$ROLE"
bash <(curl -fsSL --retry 4 "$BASE_INSTALL_URL") "$ROLE"
echo '[+] Base install complete; applying mux-v4 production migration...'
bash <(curl -fsSL --retry 4 "$MUX_UPGRADE_URL")
echo '[+] Fresh Classic443 Mux-v4 installation complete.'

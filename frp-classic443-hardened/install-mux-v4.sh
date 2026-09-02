#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] run as root' >&2; exit 1; }
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo "Usage: $0 {iran|foreign}" >&2; exit 2; }

# Compatibility entry point. Fresh installs now go directly to the finalized
# Mux-v4 installer; never stage through the retired no-mux profile.
FINAL_INSTALL_COMMIT="a6c8d7ffa375d13f6acea7eaa4c5588143f3121d"
FINAL_INSTALL_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${FINAL_INSTALL_COMMIT}/frp-classic443-hardened/install.sh"

exec bash <(curl -fsSL --retry 4 "$FINAL_INSTALL_URL") "$ROLE"

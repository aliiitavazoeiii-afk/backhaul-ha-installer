#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-}"
case "$ROLE" in
  iran|foreign|uninstall) ;;
  *) echo "Usage: $0 {iran|foreign|uninstall}" >&2; exit 2 ;;
esac

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }

# Bootstrap only the dependencies required before install.sh can parse input.
# In particular, Foreign pair-code decoding requires jq before install.sh's
# normal dependency phase is reached.
if [[ "$ROLE" != "uninstall" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y ca-certificates curl jq >/dev/null
fi

INSTALL_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/5f34a112ea2a3ad6675052f01cb693c1be6494a4/frp-tunnel-ali-pro/install.sh"
exec bash <(curl -fsSL "$INSTALL_URL") "$ROLE"

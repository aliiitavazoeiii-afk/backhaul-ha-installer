#!/usr/bin/env bash
set -Eeuo pipefail
BUNDLE="/root/dual-backhaul-foreign-a.env"
[[ -f "$BUNDLE" ]] || { echo "Missing $BUNDLE" >&2; exit 2; }
chmod 600 "$BUNDLE"
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-foreign-active-active/dual-foreign-active-active/install-dual.sh) \
  --role foreign-a \
  --bundle "$BUNDLE" \
  --replace-existing-tunnel
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-foreign-active-active/dual-foreign-active-active/enable-xray-aware-health.sh)

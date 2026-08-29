#!/usr/bin/env bash
set -Eeuo pipefail
PIN="38ef46ad8f706b35bd369b551b0780b5ce4341db"
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${PIN}/frp-tunnel-ali-custom"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 4 "${BASE}/install.sh" -o "$TMP"
# The pinned installer predates this bootstrap and referenced its panel by branch.
# Rewrite that one URL locally so both installer and panel are immutable.
sed -i "s#https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/frp-tunnel-ali-custom-v1/frp-tunnel-ali-custom/frp-tunnel#${BASE}/frp-tunnel#g" "$TMP"
exec bash "$TMP"

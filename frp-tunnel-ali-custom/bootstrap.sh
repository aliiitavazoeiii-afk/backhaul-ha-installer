#!/usr/bin/env bash
set -Eeuo pipefail

# Immutable release-candidate content snapshot. The bootstrap itself may be fetched
# by its own immutable commit URL; it then fetches installer + companion CLI from PIN.
PIN="88418b551198ca590b01be52773ae4eb5c9c0e6e"
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${PIN}/frp-tunnel-ali-custom"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 4 "${BASE}/install.sh" -o "$TMP"
export FRP_ALI_SOURCE_COMMIT="$PIN"
exec bash "$TMP"

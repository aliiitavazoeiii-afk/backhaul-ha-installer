#!/usr/bin/env bash
set -Eeuo pipefail

# Production wrapper for XHTTP + REALITY Foreign nodes.
# Xray-core v26.3.27 has a known interoperability problem with XHTTP+REALITY
# when REALITY target points to a TLS service on the same machine/loopback.
# Keep REALITY target remote for production XHTTP deployments.

PROJECT_REF="${PROJECT_REF:-xhttp-dual-sticky-failover}"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${PROJECT_REF}"
REALITY_TARGET="${REALITY_TARGET:-www.cloudflare.com:443}"
REALITY_SNI="${REALITY_SNI:-${REALITY_TARGET%%:*}}"
FORCE_NEW_CREDENTIALS="${FORCE_NEW_CREDENTIALS:-0}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required"; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
  "$BASE_URL/install-foreign.sh" -o "$TMP"
chmod +x "$TMP"

echo "============================================================"
echo "XHTTP + REALITY FOREIGN PRODUCTION INSTALL"
echo "REALITY target : $REALITY_TARGET"
echo "REALITY SNI    : $REALITY_SNI"
echo "Local decoy    : DISABLED for XHTTP production path"
echo "============================================================"

env \
  PROJECT_REF="$PROJECT_REF" \
  REALITY_TARGET="$REALITY_TARGET" \
  REALITY_SNI="$REALITY_SNI" \
  FORCE_NEW_CREDENTIALS="$FORCE_NEW_CREDENTIALS" \
  ENABLE_REALITY_DECOY=0 \
  "$TMP"

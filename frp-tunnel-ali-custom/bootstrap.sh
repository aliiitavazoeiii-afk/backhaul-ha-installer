#!/usr/bin/env bash
set -Eeuo pipefail

# The validated rc1 runtime is kept immutable; this bootstrap applies the WSS-edge
# compatibility hotfix after installation. FRP upstream requires WSS to terminate
# at a reverse proxy before plaintext WebSocket reaches frps.
RUNTIME_PIN="b0abae55f40436ead400acd4e38f84788c25ab18"
HOTFIX_PIN="bc9ba40c94af766a7e17b938b8e756b31e8a08ff"
REPO="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer"
TMP_INSTALL="$(mktemp)"
TMP_HOTFIX="$(mktemp)"
trap 'rm -f "$TMP_INSTALL" "$TMP_HOTFIX"' EXIT

curl -fsSL --retry 4 "${REPO}/${RUNTIME_PIN}/frp-tunnel-ali-custom/install.sh" -o "$TMP_INSTALL"
export FRP_ALI_SOURCE_COMMIT="$RUNTIME_PIN"

# rc1 Foreign may intentionally return NOT READY before the edge hotfix is applied.
set +e
bash "$TMP_INSTALL"
install_rc=$?
set -e

if [[ ! -r /etc/frp-tunnel-ali/meta.env ]]; then
  exit "$install_rc"
fi

curl -fsSL --retry 4 "${REPO}/${HOTFIX_PIN}/frp-tunnel-ali-custom/hotfix-wss-edge.sh" -o "$TMP_HOTFIX"
bash -n "$TMP_HOTFIX"
bash "$TMP_HOTFIX"

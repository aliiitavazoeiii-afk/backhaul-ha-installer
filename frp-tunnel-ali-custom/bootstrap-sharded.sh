#!/usr/bin/env bash
set -Eeuo pipefail

# One-command wrapper for future nodes:
# - installs the validated WSS/tcpMux=false FRP tunnel
# - applies the validated nginx WSS edge hotfix
# - on FOREIGN nodes, automatically converts frpc to four independent shards
#   with staggered one-shard-at-a-time refreshes.

BASE_BOOTSTRAP_PIN="39efc75a1d916e6beb0248a160f16159d07d6ca2"
SHARD_PIN="7cd39a615f036d14c05f94b7da2cbb6149aa0752"
REPO="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer"
TMP_BASE="$(mktemp)"
TMP_SHARD="$(mktemp)"
trap 'rm -f "$TMP_BASE" "$TMP_SHARD"' EXIT

curl -fsSL --retry 4 "${REPO}/${BASE_BOOTSTRAP_PIN}/frp-tunnel-ali-custom/bootstrap.sh" -o "$TMP_BASE"
bash -n "$TMP_BASE"
bash "$TMP_BASE"

if [[ ! -r /etc/frp-tunnel-ali/meta.env ]]; then
  echo "Tunnel metadata not found after base install; not attempting sharding." >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/frp-tunnel-ali/meta.env
ROLE="${ROLE,,}"

if [[ "$ROLE" == "foreign" ]]; then
  curl -fsSL --retry 4 "${REPO}/${SHARD_PIN}/frp-tunnel-ali-custom/enable-4-shard.sh" -o "$TMP_SHARD"
  bash -n "$TMP_SHARD"
  bash "$TMP_SHARD"
else
  echo "IRAN node: one frps + nginx WSS edge is intentional; client sharding is FOREIGN-only."
fi

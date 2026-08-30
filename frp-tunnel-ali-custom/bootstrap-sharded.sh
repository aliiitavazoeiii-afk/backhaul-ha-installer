#!/usr/bin/env bash
set -Eeuo pipefail

# One-command wrapper for future nodes:
# - installs the validated WSS/tcpMux=false FRP tunnel
# - applies the validated nginx WSS edge hotfix
# - raises nginx worker/file-descriptor capacity on IRAN nodes
# - on FOREIGN nodes, automatically converts frpc to four independent shards
#   with staggered one-shard-at-a-time refreshes.

BASE_BOOTSTRAP_PIN="39efc75a1d916e6beb0248a160f16159d07d6ca2"
SHARD_PIN="7cd39a615f036d14c05f94b7da2cbb6149aa0752"
NGINX_CAPACITY_PIN="5bf6ae599cc100443b24744f802ab1b9bc49949f"
REPO="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer"
TMP_BASE="$(mktemp)"
TMP_SHARD="$(mktemp)"
TMP_NGINX="$(mktemp)"
trap 'rm -f "$TMP_BASE" "$TMP_SHARD" "$TMP_NGINX"' EXIT

curl -fsSL --retry 4 "${REPO}/${BASE_BOOTSTRAP_PIN}/frp-tunnel-ali-custom/bootstrap.sh" -o "$TMP_BASE"
bash -n "$TMP_BASE"
bash "$TMP_BASE"

if [[ ! -r /etc/frp-tunnel-ali/meta.env ]]; then
  echo "Tunnel metadata not found after base install; not attempting post-install hardening." >&2
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
  curl -fsSL --retry 4 "${REPO}/${NGINX_CAPACITY_PIN}/frp-tunnel-ali-custom/fix-nginx-capacity.sh" -o "$TMP_NGINX"
  bash -n "$TMP_NGINX"
  bash "$TMP_NGINX"
  echo "IRAN node: one frps + nginx WSS edge is intentional; nginx capacity hardening applied; client sharding is FOREIGN-only."
fi

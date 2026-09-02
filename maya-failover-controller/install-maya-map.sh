#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

SRC="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/80b54a84b2328a2ae233b58c02b10a63c292e145/maya-failover-controller/maya-map"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL --retry 4 "$SRC" -o "$TMP"
bash -n "$TMP"
install -m 0755 "$TMP" /usr/local/bin/maya-map

echo "maya-map installed: /usr/local/bin/maya-map"
echo "Run: maya-map"

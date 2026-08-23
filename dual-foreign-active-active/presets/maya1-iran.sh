#!/usr/bin/env bash
set -Eeuo pipefail

RAW="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-foreign-active-active/dual-foreign-active-active/install-dual.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$RAW" -o "$TMP"
bash -n "$TMP"
bash "$TMP" \
  --role iran \
  --iran-ip 5.10.248.50 \
  --foreign-a-ip 193.57.9.144 \
  --foreign-b-ip 185.232.84.214 \
  --domain-a bh3.biya2film.top \
  --domain-b bh3b.biya2film.top \
  --replace-existing-tunnel

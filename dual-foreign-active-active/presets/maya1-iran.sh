#!/usr/bin/env bash
set -Eeuo pipefail

BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-foreign-active-active/dual-foreign-active-active"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL "$BASE/install-dual.sh" -o "$TMP"
bash -n "$TMP"
bash "$TMP" \
  --role iran \
  --iran-ip 5.10.248.50 \
  --foreign-a-ip 193.57.9.144 \
  --foreign-b-ip 193.57.9.192 \
  --domain-a bh3.biya2film.top \
  --domain-b bh3b.biya2film.top \
  --replace-existing-tunnel

bash <(curl -fsSL "$BASE/enable-sticky-users.sh")

#!/usr/bin/env bash
set -Eeuo pipefail

REPO='aliiitavazoeiii-afk/backhaul-ha-installer'
PIN='436fc0303fa4540bbbb6690bb589ad14d85ea7c9'
RAW="https://raw.githubusercontent.com/${REPO}/${PIN}/dual-wss-stealth"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fL --retry 4 --retry-delay 2 --retry-all-errors \
  "$RAW/install.sh" -o "$tmp"

# Force every internal helper fetch in install.sh to the same immutable,
# already-CI-validated commit rather than a mutable branch name.
sed -i "s|^BRANCH=.*$|BRANCH=${PIN}|" "$tmp"

bash -n "$tmp"
exec bash "$tmp" "$@"

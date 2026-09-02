#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_REF="77d4c0cacd1866b391efd02bb35028d07e0165e5"
SOURCE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${SOURCE_REF}/frp-tunnel-ali-shared/install.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL --retry 4 "$SOURCE_URL" -o "$TMP"

# On the Iran side, HAProxy must be allowed to start before either Foreign
# backend has registered. The selector/reconcile timer will activate the
# correct slot once its FRP backend is actually listening.
sed -i 's#^ExecStartPost=/usr/local/bin/frp-shared-select restore$#ExecStartPost=/bin/sh -c '\''/usr/local/bin/frp-shared-select restore || true'\''#' "$TMP"

grep -q "ExecStartPost=/bin/sh -c '/usr/local/bin/frp-shared-select restore || true'" "$TMP" || {
  echo "ERROR: failed to apply safe first-boot patch" >&2
  exit 1
}

bash -n "$TMP"
exec bash "$TMP" "$@"

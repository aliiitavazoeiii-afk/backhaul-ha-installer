#!/usr/bin/env bash
set -Eeuo pipefail

APP="frp-tunnel-ali-pro"
ETC="/etc/${APP}"
SERVICE="${APP}.service"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
[[ -r "$ETC/meta.env" ]] || { echo "ERROR: missing $ETC/meta.env" >&2; exit 1; }
[[ -x /usr/bin/jq || -x /bin/jq ]] || { apt-get update -y >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null; }

# shellcheck disable=SC1090
source "$ETC/meta.env"
[[ "${ROLE:-}" == "iran" ]] || { echo "ERROR: run this only on the Iran node" >&2; exit 1; }

for v in IRAN_IP FOREIGN_IP DOMAIN CONTROL_PORT PUBLIC_PORT PROFILE; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: missing $v in meta.env" >&2; exit 1; }
done

mkdir -p "$ETC"
chmod 0700 "$ETC"
if [[ -r "$ETC/token" ]]; then
  cp -a "$ETC/token" "$ETC/token.bak.$(date +%Y%m%d-%H%M%S)"
fi

TOKEN="$(openssl rand -hex 32)"
printf '%s\n' "$TOKEN" >"$ETC/token"
chmod 0600 "$ETC/token"

PAYLOAD="$(jq -cn \
  --arg iran "$IRAN_IP" \
  --arg foreign "$FOREIGN_IP" \
  --arg domain "$DOMAIN" \
  --arg cp "$CONTROL_PORT" \
  --arg pp "$PUBLIC_PORT" \
  --arg token "$TOKEN" \
  --arg profile "$PROFILE" \
  '{v:3,iran:$iran,foreign:$foreign,domain:$domain,control_port:$cp,public_port:$pp,token:$token,profile:$profile}')"
printf '%s' "$PAYLOAD" | base64 -w0 >"$ETC/pair-code.txt"
chmod 0600 "$ETC/pair-code.txt"

systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE" || { journalctl -u "$SERVICE" -n 80 --no-pager; exit 1; }

echo "PAIR ROTATED. Old Foreign clients using the previous token will no longer authenticate."
echo "New pair code (keep secret):"
cat "$ETC/pair-code.txt"
echo

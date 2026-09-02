#!/usr/bin/env bash
set -Eeuo pipefail

APP="maya-failover"
ETC="/etc/${APP}"
OPT="/opt/${APP}"
CFG="${ETC}/config.json"
SECRETS="${ETC}/secrets.env"
SERVICE="${APP}.service"
CONTROLLER_COMMIT="f96fde0cdbacbc803e14a5a3beccbf0a5ef6554f"
CONTROLLER_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${CONTROLLER_COMMIT}/maya-failover-controller/controller.py"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ -r "$CFG" ]] || { echo "Missing $CFG" >&2; exit 1; }
[[ -r "$SECRETS" ]] || { echo "Missing $SECRETS" >&2; exit 1; }
[[ -r "$OPT/controller.py" ]] || { echo "Missing installed controller" >&2; exit 1; }

command -v jq >/dev/null || { apt-get update -y >/dev/null && apt-get install -y jq >/dev/null; }
command -v curl >/dev/null || { apt-get update -y >/dev/null && apt-get install -y curl >/dev/null; }

# shellcheck disable=SC1090
source "$SECRETS"
: "${CLOUDFLARE_API_TOKEN:?Missing Cloudflare token}"
ZONE_ID="$(jq -r '.cloudflare.zone_id // empty' "$CFG")"
TTL="$(jq -r '.cloudflare.ttl // 60' "$CFG")"
[[ -n "$ZONE_ID" ]] || { echo "Missing Cloudflare zone_id" >&2; exit 1; }

CF=(-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H 'Content-Type: application/json')
API="https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records"

cf_get_name() {
  curl -fsS "${CF[@]}" "${API}?type=A&name=$1"
}

cf_get_id() {
  curl -fsS "${CF[@]}" "${API}/$1"
}

ensure_test_record() {
  local name="$1" initial_ip="$2" spare_ip="$3" json count rid current created
  json="$(cf_get_name "$name")"
  [[ "$(jq -r '.success' <<<"$json")" == "true" ]] || { echo "Cloudflare lookup failed for $name" >&2; exit 1; }
  count="$(jq -r '.result | length' <<<"$json")"
  if [[ "$count" -gt 1 ]]; then
    echo "Refusing: multiple A records exist for $name" >&2
    exit 1
  fi
  if [[ "$count" -eq 1 ]]; then
    rid="$(jq -r '.result[0].id' <<<"$json")"
    current="$(jq -r '.result[0].content' <<<"$json")"
    if [[ "$current" != "$initial_ip" && "$current" != "$spare_ip" ]]; then
      echo "Refusing: existing $name points to unexpected IP $current" >&2
      exit 1
    fi
    echo "$rid"
    return 0
  fi

  created="$(curl -fsS -X POST "${CF[@]}" "$API" --data "$(jq -cn --arg n "$name" --arg ip "$initial_ip" --argjson ttl "$TTL" '{type:"A",name:$n,content:$ip,ttl:$ttl,proxied:false}')")"
  [[ "$(jq -r '.success' <<<"$created")" == "true" ]] || { echo "Cloudflare create failed for $name" >&2; exit 1; }
  jq -r '.result.id' <<<"$created"
}

M1_MAIN="$(jq -r '.services.maya1.main_iran_ip' "$CFG")"
M1_SPARE="$(jq -r '.services.maya1.spare_iran_ip' "$CFG")"
M3_MAIN="$(jq -r '.services.maya3.main_iran_ip' "$CFG")"
M3_SPARE="$(jq -r '.services.maya3.spare_iran_ip' "$CFG")"
M1_PROD_ID="$(jq -r '.services.maya1.record_id' "$CFG")"
M3_PROD_ID="$(jq -r '.services.maya3.record_id' "$CFG")"

# Snapshot production DNS before the upgrade. These records must not change.
M1_PROD_BEFORE="$(cf_get_id "$M1_PROD_ID" | jq -r '.result.content')"
M3_PROD_BEFORE="$(cf_get_id "$M3_PROD_ID" | jq -r '.result.content')"

M1_TEST_DOMAIN="testmaya1.biya2film.top"
M3_TEST_DOMAIN="testmaya3.biya2film.top"
M1_TEST_ID="$(ensure_test_record "$M1_TEST_DOMAIN" "$M1_MAIN" "$M1_SPARE")"
M3_TEST_ID="$(ensure_test_record "$M3_TEST_DOMAIN" "$M3_MAIN" "$M3_SPARE")"

TS="$(date +%Y%m%d-%H%M%S)"
cp -a "$CFG" "${CFG}.bak-${TS}"
cp -a "$OPT/controller.py" "$OPT/controller.py.bak-${TS}"

tmp_cfg="$(mktemp)"
jq \
  --arg m1d "$M1_TEST_DOMAIN" --arg m1id "$M1_TEST_ID" \
  --arg m3d "$M3_TEST_DOMAIN" --arg m3id "$M3_TEST_ID" \
  '.services.maya1.test_domain=$m1d |
   .services.maya1.test_record_id=$m1id |
   .services.maya3.test_domain=$m3d |
   .services.maya3.test_record_id=$m3id' \
  "$CFG" >"$tmp_cfg"
install -m 0600 "$tmp_cfg" "$CFG"
rm -f "$tmp_cfg"

tmp_py="$(mktemp)"
curl -fsSL --retry 4 "$CONTROLLER_URL" -o "$tmp_py"
python3 -m py_compile "$tmp_py"
install -m 0755 "$tmp_py" "$OPT/controller.py"
rm -f "$tmp_py"

systemctl restart "$SERVICE"
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  echo "Controller failed after test-mode upgrade. Rolling back local files." >&2
  cp -a "$OPT/controller.py.bak-${TS}" "$OPT/controller.py"
  cp -a "${CFG}.bak-${TS}" "$CFG"
  systemctl restart "$SERVICE" || true
  exit 1
fi

# Assert production DNS was untouched by this upgrade.
M1_PROD_AFTER="$(cf_get_id "$M1_PROD_ID" | jq -r '.result.content')"
M3_PROD_AFTER="$(cf_get_id "$M3_PROD_ID" | jq -r '.result.content')"
if [[ "$M1_PROD_BEFORE" != "$M1_PROD_AFTER" || "$M3_PROD_BEFORE" != "$M3_PROD_AFTER" ]]; then
  echo "SAFETY ERROR: a production DNS record changed unexpectedly." >&2
  echo "MAYA1 before=$M1_PROD_BEFORE after=$M1_PROD_AFTER" >&2
  echo "MAYA3 before=$M3_PROD_BEFORE after=$M3_PROD_AFTER" >&2
  exit 1
fi

unset CLOUDFLARE_API_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID || true

echo
echo "OK Isolated test mode enabled."
echo "Production DNS unchanged:"
echo "  maya1.biya2film.top -> $M1_PROD_AFTER"
echo "  maya3.biya2film.top -> $M3_PROD_AFTER"
echo "Test records:"
echo "  $M1_TEST_DOMAIN"
echo "  $M3_TEST_DOMAIN"
echo
echo "Telegram safe-test commands:"
echo "  /teststatus"
echo "  /testspare maya1"
echo "  /testmain maya1"
echo "  /testspare maya3"
echo "  /testmain maya3"

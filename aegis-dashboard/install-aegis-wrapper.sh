#!/usr/bin/env bash
set -Eeuo pipefail

REPO='aliiitavazoeiii-afk/backhaul-ha-installer'
ORIGINAL_PIN='ef0e8a44065ca537c976858c9f9ae8f7a503313c'
ORIGINAL_URL="https://raw.githubusercontent.com/${REPO}/${ORIGINAL_PIN}/aegis-single/install.sh"
PUBLIC_ENV='/etc/aegis-dashboard/public.env'
ROUTE='/usr/local/sbin/aegis-dashboard-public-route'
ROLLBACK='/root/aegis-dashboard-backups/aegis-wrapper-rollback'

role=''
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  if [[ "${args[$i]}" == '--role' && $((i+1)) -lt ${#args[@]} ]]; then role="${args[$((i+1))]}"; fi
done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fL --retry 3 --connect-timeout 10 "$ORIGINAL_URL" -o "$tmp"
bash -n "$tmp"

if [[ "$role" != 'iran' || ! -s "$PUBLIC_ENV" ]]; then
  exec bash "$tmp" "$@"
fi

[[ -x "$ROUTE" ]] || { echo '[panel-wrapper][FAIL] public route helper missing' >&2; exit 1; }
rm -rf "$ROLLBACK"
install -d -m 0700 "$ROLLBACK"
had_state=0
if [[ -d /etc/aegis-single ]]; then had_state=1; cp -a /etc/aegis-single "$ROLLBACK/aegis-single"; fi
[[ -s /etc/haproxy/haproxy.cfg ]] && cp -a /etc/haproxy/haproxy.cfg "$ROLLBACK/haproxy.cfg"
[[ -s /etc/nginx/conf.d/aegis-single.conf ]] && cp -a /etc/nginx/conf.d/aegis-single.conf "$ROLLBACK/aegis-single.conf"
[[ -s /etc/nginx/conf.d/aegis-dashboard-public.conf ]] && cp -a /etc/nginx/conf.d/aegis-dashboard-public.conf "$ROLLBACK/aegis-dashboard-public.conf"

rollback(){
  rc=$?
  trap - ERR
  echo "[panel-wrapper] Aegis installer failed (${rc}); restoring public dashboard route" >&2
  systemctl stop aegis-server haproxy nginx >/dev/null 2>&1 || true
  if [[ "$had_state" -eq 1 ]]; then
    rm -rf /etc/aegis-single
    cp -a "$ROLLBACK/aegis-single" /etc/aegis-single
  else
    rm -rf /etc/aegis-single
    systemctl disable aegis-server >/dev/null 2>&1 || true
  fi
  if [[ -s "$ROLLBACK/haproxy.cfg" ]]; then cp -a "$ROLLBACK/haproxy.cfg" /etc/haproxy/haproxy.cfg; fi
  if [[ -s "$ROLLBACK/aegis-single.conf" ]]; then cp -a "$ROLLBACK/aegis-single.conf" /etc/nginx/conf.d/aegis-single.conf; else rm -f /etc/nginx/conf.d/aegis-single.conf; fi
  if [[ -s "$ROLLBACK/aegis-dashboard-public.conf" ]]; then cp -a "$ROLLBACK/aegis-dashboard-public.conf" /etc/nginx/conf.d/aegis-dashboard-public.conf; fi
  "$ROUTE" || true
  exit "$rc"
}
trap rollback ERR

# The original Aegis installer intentionally refuses an unknown listener on :443.
# The public dashboard owns :443 before first Aegis deployment, so free it here;
# after a successful install the route helper reattaches the panel behind HAProxy SNI.
systemctl stop haproxy nginx >/dev/null 2>&1 || true
bash "$tmp" "$@"
"$ROUTE"
trap - ERR
echo '[panel-wrapper] Aegis install completed; public dashboard route preserved.'

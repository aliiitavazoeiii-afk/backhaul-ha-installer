#!/usr/bin/env bash
set -u

BUNDLE="/root/backhaul-ha-secrets.env"
MARKER="/etc/backhaul-ha/phase2-split-tls"
TLS_PORT=9443
HTTP_PORT=9080
WSMUX_PORT=18080

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'
P=0; W=0; F=0
ok(){ printf '%b[OK]%b   %s\n' "$G" "$N" "$*"; P=$((P+1)); }
warn(){ printf '%b[WARN]%b %s\n' "$Y" "$N" "$*"; W=$((W+1)); }
fail(){ printf '%b[FAIL]%b %s\n' "$R" "$N" "$*"; F=$((F+1)); }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == iran ]] || { echo "Run this verifier on the Iran role." >&2; exit 2; }
[[ -f "$BUNDLE" ]] || { echo "Missing $BUNDLE" >&2; exit 2; }

bundle_get(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$BUNDLE" 2>/dev/null | head -n1; }
DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || true)"
[[ -n "$DOMAIN" ]] || DOMAIN="$(bundle_get DOMAIN)"
CONTROL_PATH="$(bundle_get WSS_CONTROL_PATH)"

http_public(){ curl -ksS --max-time 6 --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}$1" 2>/dev/null || true; }
health(){
  local label="$1" port="$2" out
  out="$(curl -sS -o /dev/null --max-time 5 -w '%{http_code} %{time_total}' "http://127.0.0.1:${port}/healthz" 2>/dev/null)"
  if [[ "${out%% *}" == 200 ]]; then ok "$label HTTP 200"; else fail "$label failed (${out:-curl error})"; fi
}

printf 'Phase 2 Split-TLS Verify\nDomain: %s\n\n' "$DOMAIN"
[[ -f "$MARKER" ]] && ok 'split-TLS marker present' || fail 'split-TLS marker missing'
systemctl is-active --quiet backhaul-wss-tls.service && ok 'WSS stunnel terminator active' || fail 'WSS stunnel terminator inactive'
systemctl is-active --quiet nginx && ok 'nginx active' || fail 'nginx inactive'
systemctl is-active --quiet backhaul-wss && ok 'Backhaul WSMux active' || fail 'backhaul-wss inactive'
systemctl is-active --quiet haproxy && ok 'HAProxy active' || fail 'HAProxy inactive'
nginx -t >/dev/null 2>&1 && ok 'nginx config valid' || fail 'nginx config invalid'
haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 && ok 'HAProxy config valid' || fail 'HAProxy config invalid'

ss -lntp 2>/dev/null | grep -q "127.0.0.1:${TLS_PORT}" && ok "stunnel TLS listener :${TLS_PORT} present" || fail "TLS listener :${TLS_PORT} missing"
ss -lntp 2>/dev/null | grep -q "127.0.0.1:${HTTP_PORT}" && ok "nginx HTTP listener :${HTTP_PORT} present" || fail "nginx HTTP listener :${HTTP_PORT} missing"
ss -lntp 2>/dev/null | grep -q "127.0.0.1:${WSMUX_PORT}" && ok "Backhaul WSMux listener :${WSMUX_PORT} present" || fail "Backhaul WSMux listener :${WSMUX_PORT} missing"

if grep -Eq "^[[:space:]]*server[[:space:]]+wss_control[[:space:]]+127\\.0\\.0\\.1:${TLS_PORT}([[:space:]]|$)" /etc/haproxy/haproxy.cfg 2>/dev/null; then
  ok "HAProxy backbone SNI targets stunnel :${TLS_PORT}"
else
  fail "HAProxy WSS backend is not targeting :${TLS_PORT}"
fi
if grep -Fq "accept = 127.0.0.1:${TLS_PORT}" /etc/stunnel/backhaul-wss-split.conf 2>/dev/null \
   && grep -Fq "connect = 127.0.0.1:${HTTP_PORT}" /etc/stunnel/backhaul-wss-split.conf 2>/dev/null; then
  ok "stunnel routes TLS :${TLS_PORT} to nginx HTTP :${HTTP_PORT}"
else
  fail 'stunnel split-TLS route mismatch'
fi
if grep -Eq "listen[[:space:]]+127\\.0\\.0\\.1:${HTTP_PORT};" /etc/nginx/sites-available/backhaul-decoy 2>/dev/null; then
  ok "nginx decoy is plain loopback HTTP :${HTTP_PORT}"
else
  fail 'nginx split HTTP listener config missing'
fi
if grep -Eq "listen[[:space:]]+127\\.0\\.0\\.1:${TLS_PORT}[[:space:]]+ssl" /etc/nginx/sites-available/backhaul-decoy 2>/dev/null; then
  fail 'nginx still owns TLS termination'
else
  ok 'nginx no longer owns TLS termination'
fi

code="$(curl -sS --max-time 5 -H "Host: $DOMAIN" -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/" 2>/dev/null || true)"
[[ "$code" == 200 ]] && ok 'direct nginx HTTP decoy root returns 200' || fail "direct nginx root returned ${code:-error}"
code="$(http_public /)"
[[ "$code" == 200 ]] && ok 'public-chain decoy root returns 200' || fail "public-chain root returned ${code:-error}"
probe="/verify-split-$(openssl rand -hex 8)"
code="$(http_public "$probe")"
[[ "$code" == 404 ]] && ok 'unknown public path returns generic 404' || fail "unknown public path returned ${code:-error}"
code="$(http_public "$CONTROL_PATH")"
[[ "$code" == 404 ]] && ok 'unauthenticated secret path returns generic 404' || fail "unauthenticated secret path returned ${code:-error}"

if systemctl is-active --quiet backhaul-wss-ab.service 2>/dev/null; then warn 'temporary A/B WSS stunnel still active'; else ok 'temporary A/B WSS stunnel retired'; fi
if ss -lntp 2>/dev/null | grep -q '127.0.0.1:9445'; then warn 'temporary :9445 listener still present'; else ok 'temporary :9445 listener absent'; fi

health 'WSSMux end-to-end :10444' 10444
health 'TCPMux TLS backup :11444' 11444
health 'plain TCP emergency :12444' 12444

printf '\nSummary: %d OK, %d WARN, %d FAIL\n' "$P" "$W" "$F"
((F==0))

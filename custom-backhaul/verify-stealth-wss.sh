#!/usr/bin/env bash
set -u

BUNDLE="/root/backhaul-ha-secrets.env"
PHASE2_MARKER="/etc/backhaul-ha/phase2-stealth-wss"
NGINX_PORT=9443
BACKHAUL_WSMUX_PORT=18080

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'
P=0; W=0; F=0
ok(){ printf '%b[OK]%b   %s\n' "$G" "$N" "$*"; P=$((P+1)); }
warn(){ printf '%b[WARN]%b %s\n' "$Y" "$N" "$*"; W=$((W+1)); }
fail(){ printf '%b[FAIL]%b %s\n' "$R" "$N" "$*"; F=$((F+1)); }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo "Tunnel role not found." >&2; exit 2; }
[[ -f "$BUNDLE" ]] || { echo "Missing $BUNDLE" >&2; exit 2; }

bundle_get(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$BUNDLE" 2>/dev/null | head -n1; }
DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || true)"
if [[ -z "$DOMAIN" ]]; then DOMAIN="$(bundle_get DOMAIN)"; fi
CONTROL_PATH="$(bundle_get WSS_CONTROL_PATH)"
TUNNEL_PATH="$(bundle_get WSS_TUNNEL_PATH)"

valid_path(){ [[ "$1" =~ ^/[A-Za-z0-9/_-]{16,160}$ ]]; }
http_local(){ curl -ksS --max-time 6 --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}$1" 2>/dev/null || true; }
http_public(){ curl -ksS --max-time 8 -o /dev/null -w '%{http_code}' "https://${DOMAIN}$1" 2>/dev/null || true; }
health(){
  local label="$1" url="$2" out
  out="$(curl -sS -o /dev/null --max-time 5 -w '%{http_code} %{time_total}' "$url" 2>/dev/null)"
  if [[ "${out%% *}" == 200 ]]; then
    ok "$label HTTP 200"
  else
    fail "$label failed (${out:-curl error})"
  fi
}

printf 'Phase 2 Stealth WSS Verify\nRole: %s\nDomain: %s\n\n' "$ROLE" "$DOMAIN"

if [[ -f "$PHASE2_MARKER" ]]; then ok 'Phase 2 marker present'; else warn 'Phase 2 marker missing'; fi
if valid_path "$CONTROL_PATH"; then ok 'deployment-specific control path present'; else fail 'control path missing/invalid'; fi
if valid_path "$TUNNEL_PATH"; then ok 'deployment-specific tunnel path present'; else fail 'tunnel path missing/invalid'; fi
if [[ -n "$CONTROL_PATH" && "$CONTROL_PATH" != "$TUNNEL_PATH" ]]; then ok 'control/tunnel paths are distinct'; else fail 'control/tunnel paths are not distinct'; fi

if [[ "$ROLE" == iran ]]; then
  if systemctl is-active --quiet nginx; then ok 'nginx active'; else fail 'nginx inactive'; fi
  if systemctl is-active --quiet backhaul-wss; then ok 'backhaul-wss active'; else fail 'backhaul-wss inactive'; fi
  if systemctl is-active --quiet haproxy; then ok 'haproxy active'; else fail 'haproxy inactive'; fi

  if nginx -t >/dev/null 2>&1; then ok 'nginx config valid'; else fail 'nginx config invalid'; fi
  if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then ok 'HAProxy config valid'; else fail 'HAProxy config invalid'; fi

  if grep -Eq "^[[:space:]]*bind_addr[[:space:]]*=[[:space:]]*\"127\\.0\\.0\\.1:${BACKHAUL_WSMUX_PORT}\"" /etc/backhaul/server-wss.toml 2>/dev/null; then
    ok "Backhaul WSMux bound to loopback :${BACKHAUL_WSMUX_PORT}"
  else
    fail 'Backhaul WSMux loopback bind missing'
  fi
  if grep -Eq '^[[:space:]]*transport[[:space:]]*=[[:space:]]*"wsmux"' /etc/backhaul/server-wss.toml 2>/dev/null; then
    ok 'Backhaul ingress is plain WSMux behind nginx'
  else
    fail 'Backhaul transport is not wsmux'
  fi
  if grep -Fq "ws_control_path = \"$CONTROL_PATH\"" /etc/backhaul/server-wss.toml 2>/dev/null; then ok 'server control path matches bundle'; else fail 'server control path mismatch'; fi
  if grep -Fq "ws_tunnel_path = \"$TUNNEL_PATH\"" /etc/backhaul/server-wss.toml 2>/dev/null; then ok 'server tunnel path matches bundle'; else fail 'server tunnel path mismatch'; fi
  if grep -Eq '^[[:space:]]*tls_(cert|key)[[:space:]]*=' /etc/backhaul/server-wss.toml 2>/dev/null; then
    fail 'Backhaul server still owns TLS certificate settings'
  else
    ok 'Backhaul TLS certificate settings removed'
  fi

  if grep -Eq "^[[:space:]]*server[[:space:]]+wss_control[[:space:]]+127\\.0\\.0\\.1:${NGINX_PORT}([[:space:]]|$)" /etc/haproxy/haproxy.cfg 2>/dev/null; then
    ok "HAProxy backbone SNI targets nginx :${NGINX_PORT}"
  else
    fail "HAProxy WSS backend is not nginx :${NGINX_PORT}"
  fi

  if ss -lntp 2>/dev/null | grep -q "127.0.0.1:${NGINX_PORT}"; then ok "nginx loopback TLS listener :${NGINX_PORT} present"; else fail "nginx :${NGINX_PORT} listener missing"; fi
  if ss -lntp 2>/dev/null | grep -q "127.0.0.1:${BACKHAUL_WSMUX_PORT}"; then ok "Backhaul loopback WSMux listener :${BACKHAUL_WSMUX_PORT} present"; else fail "Backhaul :${BACKHAUL_WSMUX_PORT} listener missing"; fi

  code="$(http_local /)"
  if [[ "$code" == 200 ]]; then ok 'public-chain decoy root returns HTTP 200'; else fail "decoy root returned HTTP ${code:-error}"; fi
  probe="/verify-$(openssl rand -hex 8)"
  code="$(http_local "$probe")"
  if [[ "$code" == 404 ]]; then ok 'unknown public HTTPS path returns generic 404'; else fail "unknown path returned HTTP ${code:-error}"; fi
  code="$(http_local "$CONTROL_PATH")"
  if [[ "$code" == 404 ]]; then ok 'secret control path without auth returns generic 404'; else fail "unauthenticated control path returned HTTP ${code:-error}"; fi

  health 'WSSMux end-to-end :10444' http://127.0.0.1:10444/healthz
  health 'TCPMux backup :11444' http://127.0.0.1:11444/healthz
  health 'plain TCP backup :12444' http://127.0.0.1:12444/healthz
else
  if systemctl is-active --quiet backhaul-wss; then ok 'backhaul-wss active'; else fail 'backhaul-wss inactive'; fi

  if grep -Fq "ws_control_path = \"$CONTROL_PATH\"" /etc/backhaul/client-wss.toml 2>/dev/null; then ok 'client control path matches bundle'; else fail 'client control path mismatch'; fi
  if grep -Fq "ws_tunnel_path = \"$TUNNEL_PATH\"" /etc/backhaul/client-wss.toml 2>/dev/null; then ok 'client tunnel path matches bundle'; else fail 'client tunnel path mismatch'; fi
  if grep -Eq '^[[:space:]]*tls_skip_verify[[:space:]]*=[[:space:]]*false' /etc/backhaul/client-wss.toml 2>/dev/null; then ok 'TLS certificate verification enabled'; else fail 'tls_skip_verify is not false'; fi
  if grep -Fq "tls_server_name = \"$DOMAIN\"" /etc/backhaul/client-wss.toml 2>/dev/null; then ok 'TLS server name matches backbone domain'; else fail 'TLS server name mismatch'; fi

  code="$(http_public /)"
  if [[ "$code" == 200 ]]; then ok 'public decoy root returns HTTP 200'; else fail "public decoy root returned HTTP ${code:-error}"; fi
  probe="/verify-$(openssl rand -hex 8)"
  code="$(http_public "$probe")"
  if [[ "$code" == 404 ]]; then ok 'public unknown path returns generic 404'; else fail "public unknown path returned HTTP ${code:-error}"; fi

  if journalctl -u backhaul-wss --since '-120 seconds' --no-pager 2>/dev/null | grep -q 'connected to local address 127.0.0.1:18090 successfully'; then
    ok 'recent WSSMux health data-plane traffic observed'
  else
    warn 'no recent WSSMux health data-plane log; confirm from Iran end-to-end check'
  fi
fi

printf '\nSummary: %d OK, %d WARN, %d FAIL\n' "$P" "$W" "$F"
((F==0))

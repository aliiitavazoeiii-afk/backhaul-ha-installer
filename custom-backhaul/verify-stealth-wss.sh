#!/usr/bin/env bash
set -u

BUNDLE="/root/backhaul-ha-secrets.env"
PHASE2_MARKER="/etc/backhaul-ha/phase2-stealth-wss"
NGINX_PORT=9443
BACKHAUL_WSMUX_PORT=18080

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
P=0; W=0; F=0
ok(){ printf '%b[OK]%b   %s\n' "$G" "$N" "$*"; P=$((P+1)); }
warn(){ printf '%b[WARN]%b %s\n' "$Y" "$N" "$*"; W=$((W+1)); }
fail(){ printf '%b[FAIL]%b %s\n' "$R" "$N" "$*"; F=$((F+1)); }
info(){ printf '%b[INFO]%b %s\n' "$C" "$N" "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo "Tunnel role not found." >&2; exit 2; }
[[ -f "$BUNDLE" ]] || { echo "Missing $BUNDLE" >&2; exit 2; }

bundle_get(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$BUNDLE" 2>/dev/null | head -n1; }
DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || true)"
[[ -n "$DOMAIN" ]] || DOMAIN="$(bundle_get DOMAIN)"
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

[[ -f "$PHASE2_MARKER" ]] && ok 'Phase 2 marker present' || warn 'Phase 2 marker missing'
valid_path "$CONTROL_PATH" && ok 'deployment-specific control path present' || fail 'control path missing/invalid'
valid_path "$TUNNEL_PATH" && ok 'deployment-specific tunnel path present' || fail 'tunnel path missing/invalid'
[[ -n "$CONTROL_PATH" && "$CONTROL_PATH" != "$TUNNEL_PATH" ]] && ok 'control/tunnel paths are distinct' || fail 'control/tunnel paths are not distinct'

if [[ "$ROLE" == iran ]]; then
  systemctl is-active --quiet nginx && ok 'nginx active' || fail 'nginx inactive'
  systemctl is-active --quiet backhaul-wss && ok 'backhaul-wss active' || fail 'backhaul-wss inactive'
  systemctl is-active --quiet haproxy && ok 'haproxy active' || fail 'haproxy inactive'

  nginx -t >/dev/null 2>&1 && ok 'nginx config valid' || fail 'nginx config invalid'
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 && ok 'HAProxy config valid' || fail 'HAProxy config invalid'

  grep -Eq '^[[:space:]]*bind_addr[[:space:]]*=[[:space:]]*"127\.0\.0\.1:18080"' /etc/backhaul/server-wss.toml 2>/dev/null \
    && ok 'Backhaul WSMux bound to loopback :18080' || fail 'Backhaul WSMux loopback bind missing'
  grep -Eq '^[[:space:]]*transport[[:space:]]*=[[:space:]]*"wsmux"' /etc/backhaul/server-wss.toml 2>/dev/null \
    && ok 'Backhaul ingress is plain WSMux behind nginx' || fail 'Backhaul transport is not wsmux'
  grep -Fq "ws_control_path = \"$CONTROL_PATH\"" /etc/backhaul/server-wss.toml 2>/dev/null \
    && ok 'server control path matches bundle' || fail 'server control path mismatch'
  grep -Fq "ws_tunnel_path = \"$TUNNEL_PATH\"" /etc/backhaul/server-wss.toml 2>/dev/null \
    && ok 'server tunnel path matches bundle' || fail 'server tunnel path mismatch'
  if grep -Eq '^[[:space:]]*tls_(cert|key)[[:space:]]*=' /etc/backhaul/server-wss.toml 2>/dev/null; then
    fail 'Backhaul server still owns TLS certificate settings'
  else
    ok 'Backhaul TLS certificate settings removed'
  fi

  grep -Eq '^[[:space:]]*server[[:space:]]+wss_control[[:space:]]+127\.0\.0\.1:9443([[:space:]]|$)' /etc/haproxy/haproxy.cfg 2>/dev/null \
    && ok 'HAProxy backbone SNI targets nginx :9443' || fail 'HAProxy WSS backend is not nginx :9443'

  ss -lntp 2>/dev/null | grep -q '127.0.0.1:9443' && ok 'nginx loopback TLS listener :9443 present' || fail 'nginx :9443 listener missing'
  ss -lntp 2>/dev/null | grep -q '127.0.0.1:18080' && ok 'Backhaul loopback WSMux listener :18080 present' || fail 'Backhaul :18080 listener missing'

  code="$(http_local /)"
  [[ "$code" == 200 ]] && ok 'public-chain decoy root returns HTTP 200' || fail "decoy root returned HTTP ${code:-error}"
  probe="/verify-$(openssl rand -hex 8)"
  code="$(http_local "$probe")"
  [[ "$code" == 404 ]] && ok 'unknown public HTTPS path returns generic 404' || fail "unknown path returned HTTP ${code:-error}"
  code="$(http_local "$CONTROL_PATH")"
  [[ "$code" == 404 ]] && ok 'secret control path without auth returns generic 404' || fail "unauthenticated control path returned HTTP ${code:-error}"

  health 'WSSMux end-to-end :10444' http://127.0.0.1:10444/healthz
  health 'TCPMux backup :11444' http://127.0.0.1:11444/healthz
  health 'plain TCP backup :12444' http://127.0.0.1:12444/healthz
else
  systemctl is-active --quiet backhaul-wss && ok 'backhaul-wss active' || fail 'backhaul-wss inactive'

  grep -Fq "ws_control_path = \"$CONTROL_PATH\"" /etc/backhaul/client-wss.toml 2>/dev/null \
    && ok 'client control path matches bundle' || fail 'client control path mismatch'
  grep -Fq "ws_tunnel_path = \"$TUNNEL_PATH\"" /etc/backhaul/client-wss.toml 2>/dev/null \
    && ok 'client tunnel path matches bundle' || fail 'client tunnel path mismatch'
  grep -Eq '^[[:space:]]*tls_skip_verify[[:space:]]*=[[:space:]]*false' /etc/backhaul/client-wss.toml 2>/dev/null \
    && ok 'TLS certificate verification enabled' || fail 'tls_skip_verify is not false'
  grep -Fq "tls_server_name = \"$DOMAIN\"" /etc/backhaul/client-wss.toml 2>/dev/null \
    && ok 'TLS server name matches backbone domain' || fail 'TLS server name mismatch'

  code="$(http_public /)"
  [[ "$code" == 200 ]] && ok 'public decoy root returns HTTP 200' || fail "public decoy root returned HTTP ${code:-error}"
  probe="/verify-$(openssl rand -hex 8)"
  code="$(http_public "$probe")"
  [[ "$code" == 404 ]] && ok 'public unknown path returns generic 404' || fail "public unknown path returned HTTP ${code:-error}"

  if journalctl -u backhaul-wss --since '-120 seconds' --no-pager 2>/dev/null | grep -q 'connected to local address 127.0.0.1:18090 successfully'; then
    ok 'recent WSSMux health data-plane traffic observed'
  else
    warn 'no recent WSSMux health data-plane log; confirm from Iran end-to-end check'
  fi
fi

printf '\nSummary: %d OK, %d WARN, %d FAIL\n' "$P" "$W" "$F"
((F==0))

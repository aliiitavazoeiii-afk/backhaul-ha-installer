#!/usr/bin/env bash
set -u

BUNDLE="/root/backhaul-ha-secrets.env"
MARKER="/etc/backhaul-ha/phase3-tcptls"
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

bundle_get(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$BUNDLE" | head -n1; }
IRAN_IP="$(bundle_get IRAN_IP)"
TCP_TLS_DOMAIN="$(bundle_get TCP_TLS_DOMAIN)"

check_tls() {
  local host="$1" target="$2" port="$3"
  python3 - "$host" "$target" "$port" <<'PY' >/dev/null 2>&1
import socket, ssl, sys
host, target, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
ctx = ssl.create_default_context()
with socket.create_connection((target, port), timeout=6) as raw:
    with ctx.wrap_socket(raw, server_hostname=host) as tls:
        assert tls.version()
PY
}

health() {
  local label="$1" url="$2" out
  out="$(curl -sS -o /dev/null --max-time 5 -w '%{http_code} %{time_total}' "$url" 2>/dev/null)"
  if [[ "${out%% *}" == 200 ]]; then ok "$label HTTP 200"; else fail "$label failed (${out:-curl error})"; fi
}

printf 'Phase 3 TLS-wrapped TCPMux Verify\nRole: %s\nDomain: %s\n\n' "$ROLE" "$TCP_TLS_DOMAIN"

if [[ -f "$MARKER" ]]; then ok 'Phase 3 marker present'; else fail 'Phase 3 marker missing'; fi
if [[ -n "$TCP_TLS_DOMAIN" ]]; then ok 'separate TCPMux TLS hostname present'; else fail 'TCP_TLS_DOMAIN missing'; fi

if [[ "$ROLE" == iran ]]; then
  if systemctl is-active --quiet backhaul-tcptls.service; then ok 'Phase 3 stunnel server active'; else fail 'Phase 3 stunnel server inactive'; fi
  if systemctl is-active --quiet backhaul.service; then ok 'Backhaul TCPMux server active'; else fail 'Backhaul TCPMux server inactive'; fi
  if systemctl is-active --quiet haproxy.service; then ok 'HAProxy active'; else fail 'HAProxy inactive'; fi

  if grep -Eq '^[[:space:]]*bind_addr[[:space:]]*=[[:space:]]*"127\.0\.0\.1:18081"' /etc/backhaul/server.toml 2>/dev/null; then ok 'raw TCPMux bound to loopback :18081'; else fail 'raw TCPMux loopback bind missing'; fi
  if ss -lntp 2>/dev/null | grep -q '127.0.0.1:18081'; then ok 'Backhaul raw TCPMux listener :18081 present'; else fail 'Backhaul raw TCPMux :18081 missing'; fi
  if ss -lntp 2>/dev/null | grep -q '127.0.0.1:9444'; then ok 'stunnel TLS listener :9444 present'; else fail 'stunnel TLS :9444 missing'; fi
  if ss -lntp 2>/dev/null | grep -q ':3080 '; then fail 'legacy raw TCPMux :3080 still exposed/listening'; else ok 'legacy raw TCPMux :3080 not listening'; fi

  if grep -Fq "acl is_tcptls req.ssl_sni -i $TCP_TLS_DOMAIN" /etc/haproxy/haproxy.cfg 2>/dev/null; then ok 'HAProxy has separate TCPMux SNI ACL'; else fail 'HAProxy TCPMux SNI ACL missing'; fi
  if grep -Fq 'use_backend backhaul_tcptls if is_tcptls' /etc/haproxy/haproxy.cfg 2>/dev/null; then ok 'HAProxy routes TCPMux SNI to TLS wrapper'; else fail 'HAProxy TCPMux route missing'; fi
  if grep -Fq 'server tcptls_control 127.0.0.1:9444' /etc/haproxy/haproxy.cfg 2>/dev/null; then ok 'HAProxy TCPMux backend targets stunnel :9444'; else fail 'HAProxy TCPMux backend mismatch'; fi

  if check_tls "$TCP_TLS_DOMAIN" 127.0.0.1 443; then ok 'local public-chain TLS handshake and certificate verification pass'; else fail 'local public-chain TLS handshake failed'; fi

  health 'WSSMux primary :10444' http://127.0.0.1:10444/healthz
  health 'TCPMux TLS backup :11444' http://127.0.0.1:11444/healthz
  health 'plain TCP emergency :12444' http://127.0.0.1:12444/healthz
else
  if systemctl is-active --quiet backhaul-tcptls.service; then ok 'Phase 3 stunnel client active'; else fail 'Phase 3 stunnel client inactive'; fi
  if systemctl is-active --quiet backhaul.service; then ok 'Backhaul TCPMux client active'; else fail 'Backhaul TCPMux client inactive'; fi
  if ss -lntp 2>/dev/null | grep -q '127.0.0.1:13080'; then ok 'Foreign local stunnel listener :13080 present'; else fail 'Foreign stunnel :13080 missing'; fi
  if grep -Eq '^[[:space:]]*remote_addr[[:space:]]*=[[:space:]]*"127\.0\.0\.1:13080"' /etc/backhaul/client.toml 2>/dev/null; then ok 'Backhaul TCPMux dials local TLS wrapper'; else fail 'Backhaul TCPMux remote_addr is not local TLS wrapper'; fi

  if grep -Fq "connect = ${TCP_TLS_DOMAIN}:443" /etc/stunnel/backhaul-tcpmux.conf 2>/dev/null; then ok 'stunnel connects to separate SNI on public :443'; else fail 'stunnel remote target mismatch'; fi
  if grep -Fq 'verifyChain = yes' /etc/stunnel/backhaul-tcpmux.conf 2>/dev/null && grep -Fq "checkHost = ${TCP_TLS_DOMAIN}" /etc/stunnel/backhaul-tcpmux.conf 2>/dev/null && grep -Fq "sni = ${TCP_TLS_DOMAIN}" /etc/stunnel/backhaul-tcpmux.conf 2>/dev/null; then
    ok 'TLS chain, hostname and SNI verification configured'
  else
    fail 'TLS verification/SNI settings incomplete'
  fi

  resolved="$(getent ahostsv4 "$TCP_TLS_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ "$resolved" == "$IRAN_IP" ]]; then ok "$TCP_TLS_DOMAIN resolves to Iran IP"; else fail "$TCP_TLS_DOMAIN resolves to ${resolved:-none}, expected $IRAN_IP"; fi
  if check_tls "$TCP_TLS_DOMAIN" "$TCP_TLS_DOMAIN" 443; then ok 'public TLS handshake and certificate verification pass'; else fail 'public TLS handshake/certificate verification failed'; fi

  if journalctl -u backhaul.service --since '-180 seconds' --no-pager 2>/dev/null | grep -q 'connected to local address 127.0.0.1:18090 successfully'; then ok 'recent TCPMux health data-plane traffic observed'; else warn 'no recent TCPMux health data-plane log; verify from Iran end-to-end health'; fi
fi

info 'Phase 3 wraps TCPMux in independently authenticated TLS; it does not make flow metadata unclassifiable.'
printf '\nSummary: %d OK, %d WARN, %d FAIL\n' "$P" "$W" "$F"
((F==0))

#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE="/root/backhaul-ha-secrets.env"
PHASE2_MARKER="/etc/backhaul-ha/phase2-stealth-wss"
SPLIT_MARKER="/etc/backhaul-ha/phase2-split-tls"
BACKUP_PTR="/etc/backhaul-ha/phase2-split-backup-path"
NGINX_SITE="/etc/nginx/sites-available/backhaul-decoy"
NGINX_LINK="/etc/nginx/sites-enabled/backhaul-decoy"
AB_NGINX_SITE="/etc/nginx/sites-available/backhaul-decoy-ab-http"
AB_NGINX_LINK="/etc/nginx/sites-enabled/backhaul-decoy-ab-http"
STUNNEL_CONF="/etc/stunnel/backhaul-wss-split.conf"
STUNNEL_UNIT="/etc/systemd/system/backhaul-wss-tls.service"
AB_STUNNEL_CONF="/etc/stunnel/backhaul-wss-ab.conf"
AB_STUNNEL_UNIT="/etc/systemd/system/backhaul-wss-ab.service"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/backhaul-wss-split-tls"
TLS_PORT=9443
HTTP_PORT=9080
WSMUX_PORT=18080

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == iran ]] || { echo "[x] This migration runs on the Iran role only." >&2; exit 2; }
[[ -f "$BUNDLE" ]] || { echo "[x] Missing $BUNDLE" >&2; exit 2; }
[[ -f "$PHASE2_MARKER" ]] || { echo "[x] Phase 2 marker missing." >&2; exit 2; }
[[ -f /etc/haproxy/haproxy.cfg ]] || { echo "[x] HAProxy config missing." >&2; exit 2; }
[[ -f /etc/backhaul/server-wss.toml ]] || { echo "[x] Backhaul WSS config missing." >&2; exit 2; }

bundle_get(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$BUNDLE" 2>/dev/null | head -n1; }
DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || true)"
[[ -n "$DOMAIN" ]] || DOMAIN="$(bundle_get DOMAIN)"
CONTROL_PATH="$(bundle_get WSS_CONTROL_PATH)"
TUNNEL_PATH="$(bundle_get WSS_TUNNEL_PATH)"
[[ -n "$DOMAIN" && -n "$CONTROL_PATH" && -n "$TUNNEL_PATH" ]] || { echo "[x] Phase 2 domain/secret paths missing." >&2; exit 3; }
[[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]] || { echo "[x] Certificate for $DOMAIN missing." >&2; exit 3; }

init_backup(){
  install -d -m 0755 /etc/backhaul-ha
  if [[ -f "$BACKUP_PTR" ]]; then
    BACKUP_ROOT="$(cat "$BACKUP_PTR")"
    [[ -d "$BACKUP_ROOT" ]] || { echo "[x] Saved backup directory missing: $BACKUP_ROOT" >&2; exit 4; }
    return
  fi
  BACKUP_ROOT="/root/backhaul-ha-backups/phase2-split-$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$BACKUP_ROOT"
  : > "$BACKUP_ROOT/.missing"
  printf '%s\n' "$BACKUP_ROOT" > "$BACKUP_PTR"
  chmod 0600 "$BACKUP_PTR"
}

backup_path(){
  local p="$1"
  [[ -e "$BACKUP_ROOT$p" || -L "$BACKUP_ROOT$p" ]] && return 0
  if [[ -e "$p" || -L "$p" ]]; then
    mkdir -p "$BACKUP_ROOT$(dirname "$p")"
    cp -a -- "$p" "$BACKUP_ROOT$p"
  else
    printf '%s\n' "$p" >> "$BACKUP_ROOT/.missing"
  fi
}

init_backup
for p in \
  "$NGINX_SITE" "$NGINX_LINK" /etc/haproxy/haproxy.cfg \
  "$STUNNEL_CONF" "$STUNNEL_UNIT" "$RENEW_HOOK" \
  "$AB_NGINX_SITE" "$AB_NGINX_LINK" "$AB_STUNNEL_CONF" "$AB_STUNNEL_UNIT"; do
  backup_path "$p"
done

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y stunnel4 nginx ca-certificates
install -d -m 0755 /etc/stunnel /etc/letsencrypt/renewal-hooks/deploy /etc/systemd/system

# Replace the original nginx TLS terminator with a loopback-only HTTP/WebSocket
# router. TLS is terminated by stunnel on :9443, avoiding the throughput stalls
# reproduced with nginx TLS termination while preserving the decoy and secret
# WebSocket path behavior.
rm -f "$AB_NGINX_LINK"
cat > "$NGINX_SITE" <<CFG
server {
    listen 127.0.0.1:${HTTP_PORT};
    server_name ${DOMAIN};
    server_tokens off;

    root /var/www/backhaul-decoy;
    index index.html;
    access_log off;

    location = ${CONTROL_PATH} {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header X-User-Id \$http_x_user_id;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_pass http://127.0.0.1:${WSMUX_PORT};
    }

    location ^~ ${TUNNEL_PATH}/ {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header X-User-Id \$http_x_user_id;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_pass http://127.0.0.1:${WSMUX_PORT};
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
CFG
ln -sfn "$NGINX_SITE" "$NGINX_LINK"
nginx -t

cat > "$STUNNEL_CONF" <<CFG
foreground = yes
syslog = no
debug = notice
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[backhaul-wss-split]
accept = 127.0.0.1:${TLS_PORT}
connect = 127.0.0.1:${HTTP_PORT}
cert = /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
key = /etc/letsencrypt/live/${DOMAIN}/privkey.pem
sslVersionMin = TLSv1.2
TIMEOUTconnect = 10
TIMEOUTclose = 5
TIMEOUTidle = 43200
CFG
chmod 0600 "$STUNNEL_CONF"

cat > "$STUNNEL_UNIT" <<UNIT
[Unit]
Description=Phase 2 TLS terminator for stealth WSS
After=network-online.target nginx.service
Wants=network-online.target
Requires=nginx.service

[Service]
Type=simple
ExecStart=/usr/bin/stunnel ${STUNNEL_CONF}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

cat > "$RENEW_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -eu
if systemctl is-enabled --quiet backhaul-wss-tls.service 2>/dev/null; then
  systemctl restart backhaul-wss-tls.service
fi
HOOK
chmod 0755 "$RENEW_HOOK"

# Normalize HAProxy from either the normal Phase 2 :9443 state or the temporary
# A/B :9445 state back to the stable public chain. :9443 is now stunnel, not nginx.
python3 - /etc/haproxy/haproxy.cfg <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
pat = r'(?m)^(\s*server\s+wss_control\s+)127\.0\.0\.1:(?:9443|9445)(\s*.*)$'
new, n = re.subn(pat, r'\g<1>127.0.0.1:9443\g<2>', s, count=1)
if n != 1:
    raise SystemExit('[x] Could not normalize HAProxy wss_control backend from :9443/:9445.')
p.write_text(new)
PY
haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null

# Restart nginx rather than graceful-reload so the old TLS :9443 listener is
# guaranteed to be released before stunnel binds that port.
systemctl restart nginx
sleep 1
ss -lntp 2>/dev/null | grep -q "127.0.0.1:${HTTP_PORT}" || { echo "[x] nginx HTTP listener :${HTTP_PORT} missing." >&2; exit 5; }
if ss -lntp 2>/dev/null | grep -q "127.0.0.1:${TLS_PORT}"; then
  echo "[x] :${TLS_PORT} is still occupied before starting final stunnel." >&2
  ss -lntp 2>/dev/null | grep "127.0.0.1:${TLS_PORT}" >&2 || true
  exit 5
fi

systemctl daemon-reload
systemctl enable backhaul-wss-tls.service >/dev/null 2>&1
systemctl restart backhaul-wss-tls.service
sleep 1
systemctl is-active --quiet backhaul-wss-tls.service || { echo "[x] final WSS stunnel service inactive." >&2; exit 5; }
ss -lntp 2>/dev/null | grep -q "127.0.0.1:${TLS_PORT}" || { echo "[x] final WSS TLS listener :${TLS_PORT} missing." >&2; exit 5; }

systemctl reload haproxy 2>/dev/null || systemctl restart haproxy

# Retire the temporary A/B terminator now that HAProxy points at the final one.
if systemctl list-unit-files 2>/dev/null | grep -q '^backhaul-wss-ab.service'; then
  systemctl disable --now backhaul-wss-ab.service >/dev/null 2>&1 || true
fi
rm -f "$AB_STUNNEL_UNIT" "$AB_STUNNEL_CONF" "$AB_NGINX_LINK" "$AB_NGINX_SITE"
systemctl daemon-reload

# Local layer checks.
code="$(curl -sS --max-time 5 -H "Host: $DOMAIN" -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/" 2>/dev/null || true)"
[[ "$code" == 200 ]] || { echo "[x] nginx HTTP decoy root returned ${code:-error}." >&2; exit 6; }
code="$(curl -ksS --max-time 6 --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null || true)"
[[ "$code" == 200 ]] || { echo "[x] public-chain decoy root returned ${code:-error}." >&2; exit 6; }
probe="/split-verify-$(openssl rand -hex 8)"
code="$(curl -ksS --max-time 6 --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}${probe}" 2>/dev/null || true)"
[[ "$code" == 404 ]] || { echo "[x] random public path returned ${code:-error}, expected 404." >&2; exit 6; }
code="$(curl -ksS --max-time 6 --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}${CONTROL_PATH}" 2>/dev/null || true)"
[[ "$code" == 404 ]] || { echo "[x] unauthenticated secret path returned ${code:-error}, expected 404." >&2; exit 6; }

cat > "$SPLIT_MARKER" <<EOF
role=iran
domain=$DOMAIN
tls_terminator=stunnel
stunnel_port=$TLS_PORT
nginx_http_port=$HTTP_PORT
backhaul_wsmux_port=$WSMUX_PORT
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "$SPLIT_MARKER"

printf '[+] Phase 2 split-TLS migration complete.\n'
printf '[+] Public :443 -> HAProxy SNI -> stunnel :%s -> nginx HTTP :%s -> Backhaul WSMux :%s.\n' "$TLS_PORT" "$HTTP_PORT" "$WSMUX_PORT"
printf '[+] Decoy root/404 behavior passed; temporary :9445 A/B service retired.\n'
printf '[i] Foreign backhaul-wss should reconnect automatically. If :10444 is not healthy after a few seconds, restart backhaul-wss on Foreign once.\n'

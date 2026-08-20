#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE="/root/backhaul-ha-secrets.env"
MARKER="/etc/backhaul-ha/custom-v2"
PHASE2_MARKER="/etc/backhaul-ha/phase2-stealth-wss"
BACKUP_PTR="/etc/backhaul-ha/phase2-backup-path"
NGINX_PORT=9443
BACKHAUL_WSMUX_PORT=18080
NGINX_SITE="/etc/nginx/sites-available/backhaul-decoy"
NGINX_LINK="/etc/nginx/sites-enabled/backhaul-decoy"
DECOY_ROOT="/var/www/backhaul-decoy"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || { echo "[x] Tunnel role not detected." >&2; exit 2; }
[[ -f "$BUNDLE" ]] || { echo "[x] Missing $BUNDLE" >&2; exit 2; }
[[ -f "$MARKER" ]] || { echo "[x] Custom Backhaul v2 marker missing. Install/test Phase 1 first." >&2; exit 3; }
[[ -x /usr/local/bin/backhaul ]] || { echo "[x] Backhaul binary missing." >&2; exit 3; }

bundle_get() {
  sed -n "s/^${1}='\([^']*\)'$/\1/p" "$BUNDLE" | head -n1
}

bundle_set() {
  local key="$1" value="$2"
  if grep -q "^${key}='" "$BUNDLE"; then
    sed -i "s|^${key}='[^']*'$|${key}='${value}'|" "$BUNDLE"
  else
    printf "%s='%s'\n" "$key" "$value" >> "$BUNDLE"
  fi
  chmod 0600 "$BUNDLE"
}

valid_path() {
  [[ "$1" =~ ^/[A-Za-z0-9/_-]{16,160}$ ]]
}

set_toml_string() {
  local file="$1" key="$2" value="$3"
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*$|${key} = \"${value}\"|" "$file"
  else
    printf '\n%s = "%s"\n' "$key" "$value" >> "$file"
  fi
}

set_toml_bool() {
  local file="$1" key="$2" value="$3"
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*$|${key} = ${value}|" "$file"
  else
    printf '\n%s = %s\n' "$key" "$value" >> "$file"
  fi
}

init_backup() {
  install -d -m 0755 /etc/backhaul-ha
  if [[ -f "$BACKUP_PTR" ]]; then
    BACKUP_ROOT="$(cat "$BACKUP_PTR")"
    [[ -d "$BACKUP_ROOT" ]] || { echo "[x] Saved Phase 2 backup directory is missing: $BACKUP_ROOT" >&2; exit 4; }
    return
  fi

  BACKUP_ROOT="/root/backhaul-ha-backups/phase2-$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$BACKUP_ROOT"
  : > "$BACKUP_ROOT/.missing"
  printf 'nginx_installed=%s\n' "$(command -v nginx >/dev/null 2>&1 && echo 1 || echo 0)" > "$BACKUP_ROOT/.meta"
  printf 'nginx_active=%s\n' "$(systemctl is-active --quiet nginx 2>/dev/null && echo 1 || echo 0)" >> "$BACKUP_ROOT/.meta"
  printf '%s\n' "$BACKUP_ROOT" > "$BACKUP_PTR"
  chmod 0600 "$BACKUP_PTR"
}

backup_path() {
  local p="$1"
  [[ -e "$BACKUP_ROOT$p" || -L "$BACKUP_ROOT$p" ]] && return 0
  if [[ -e "$p" || -L "$p" ]]; then
    mkdir -p "$BACKUP_ROOT$(dirname "$p")"
    cp -a -- "$p" "$BACKUP_ROOT$p"
  else
    printf '%s\n' "$p" >> "$BACKUP_ROOT/.missing"
  fi
}

DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || true)"
[[ -n "$DOMAIN" ]] || DOMAIN="$(bundle_get DOMAIN)"
[[ -n "$DOMAIN" ]] || { echo "[x] Backbone domain missing." >&2; exit 2; }

CONTROL_PATH="$(bundle_get WSS_CONTROL_PATH)"
TUNNEL_PATH="$(bundle_get WSS_TUNNEL_PATH)"

if [[ "$ROLE" == "iran" ]]; then
  [[ -f /etc/backhaul/server-wss.toml ]] || { echo "[x] Missing /etc/backhaul/server-wss.toml" >&2; exit 5; }
  [[ -f /etc/haproxy/haproxy.cfg ]] || { echo "[x] Missing HAProxy config." >&2; exit 5; }
  [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || { echo "[x] Missing certificate for $DOMAIN" >&2; exit 5; }
  [[ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]] || { echo "[x] Missing private key for $DOMAIN" >&2; exit 5; }

  if ! valid_path "$CONTROL_PATH"; then
    CONTROL_PATH="/assets/v3/$(openssl rand -hex 16)"
    bundle_set WSS_CONTROL_PATH "$CONTROL_PATH"
  fi
  if ! valid_path "$TUNNEL_PATH"; then
    TUNNEL_PATH="/api/socket/$(openssl rand -hex 16)"
    bundle_set WSS_TUNNEL_PATH "$TUNNEL_PATH"
  fi
  [[ "$CONTROL_PATH" != "$TUNNEL_PATH" ]] || { echo "[x] Control/tunnel paths must differ." >&2; exit 5; }

  init_backup
  backup_path /etc/backhaul/server-wss.toml
  backup_path /etc/haproxy/haproxy.cfg
  backup_path "$BUNDLE"
  backup_path "$NGINX_SITE"
  backup_path "$NGINX_LINK"
  backup_path "$DECOY_ROOT"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nginx

  # Do not let the distro default site occupy :80; the existing Certbot flow
  # can continue using HTTP-01 independently.
  if [[ -L /etc/nginx/sites-enabled/default && "$(readlink -f /etc/nginx/sites-enabled/default)" == "/etc/nginx/sites-available/default" ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  install -d -m 0755 "$DECOY_ROOT"
  cat > "$DECOY_ROOT/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>
<body><main><h1>Welcome</h1><p>The service is online.</p></main></body>
</html>
HTML

  cat > "$NGINX_SITE" <<CFG
server {
    listen 127.0.0.1:${NGINX_PORT} ssl http2;
    server_name ${DOMAIN};
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:BHDecoySSL:10m;
    ssl_session_timeout 1d;

    root ${DECOY_ROOT};
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
        proxy_pass http://127.0.0.1:${BACKHAUL_WSMUX_PORT};
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
        proxy_pass http://127.0.0.1:${BACKHAUL_WSMUX_PORT};
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
CFG
  ln -sfn "$NGINX_SITE" "$NGINX_LINK"

  set_toml_string /etc/backhaul/server-wss.toml bind_addr "127.0.0.1:${BACKHAUL_WSMUX_PORT}"
  set_toml_string /etc/backhaul/server-wss.toml transport "wsmux"
  set_toml_string /etc/backhaul/server-wss.toml ws_control_path "$CONTROL_PATH"
  set_toml_string /etc/backhaul/server-wss.toml ws_tunnel_path "$TUNNEL_PATH"
  sed -i -E '/^[[:space:]]*tls_cert[[:space:]]*=/d; /^[[:space:]]*tls_key[[:space:]]*=/d' /etc/backhaul/server-wss.toml

  if grep -q 'server wss_control 127.0.0.1:8443' /etc/haproxy/haproxy.cfg; then
    sed -i "s/server wss_control 127.0.0.1:8443/server wss_control 127.0.0.1:${NGINX_PORT}/" /etc/haproxy/haproxy.cfg
  elif ! grep -q "server wss_control 127.0.0.1:${NGINX_PORT}" /etc/haproxy/haproxy.cfg; then
    echo "[x] Could not find expected HAProxy backhaul_wss server line." >&2
    exit 6
  fi

  nginx -t
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null

  systemctl daemon-reload
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart backhaul-wss
  systemctl restart nginx
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy

  sleep 2
  ss -lntp 2>/dev/null | grep -q "127.0.0.1:${BACKHAUL_WSMUX_PORT}" || { echo "[x] Backhaul WSMux loopback listener missing." >&2; exit 7; }
  ss -lntp 2>/dev/null | grep -q "127.0.0.1:${NGINX_PORT}" || { echo "[x] nginx decoy TLS listener missing." >&2; exit 7; }

  code="$(curl -ksS --resolve "${DOMAIN}:${NGINX_PORT}:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}:${NGINX_PORT}/")"
  [[ "$code" == 200 ]] || { echo "[x] Decoy HTTPS root returned HTTP $code" >&2; exit 7; }

  cat > "$PHASE2_MARKER" <<EOF
role=iran
domain=$DOMAIN
nginx_port=$NGINX_PORT
backhaul_wsmux_port=$BACKHAUL_WSMUX_PORT
control_path=$CONTROL_PATH
tunnel_path=$TUNNEL_PATH
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 0600 "$PHASE2_MARKER"

  echo "[+] Phase 2 Iran ingress ready."
  echo "[+] Public SNI now terminates on nginx decoy TLS; Backhaul WSMux is loopback-only."
  echo "[i] WSS will remain on TCPMux/plain failover until the Foreign client receives the new secret paths."
  echo "[i] Copy $BUNDLE to Foreign, then run this same Phase 2 script there."
else
  valid_path "$CONTROL_PATH" || { echo "[x] WSS_CONTROL_PATH missing/invalid in bundle. Run Phase 2 on Iran first and copy the updated bundle." >&2; exit 8; }
  valid_path "$TUNNEL_PATH" || { echo "[x] WSS_TUNNEL_PATH missing/invalid in bundle. Run Phase 2 on Iran first and copy the updated bundle." >&2; exit 8; }
  [[ -f /etc/backhaul/client-wss.toml ]] || { echo "[x] Missing /etc/backhaul/client-wss.toml" >&2; exit 5; }

  init_backup
  backup_path /etc/backhaul/client-wss.toml
  backup_path "$BUNDLE"

  set_toml_string /etc/backhaul/client-wss.toml ws_control_path "$CONTROL_PATH"
  set_toml_string /etc/backhaul/client-wss.toml ws_tunnel_path "$TUNNEL_PATH"
  set_toml_string /etc/backhaul/client-wss.toml tls_server_name "$DOMAIN"
  set_toml_bool /etc/backhaul/client-wss.toml tls_skip_verify false
  set_toml_string /etc/backhaul/client-wss.toml ws_origin "https://${DOMAIN}"

  systemctl restart backhaul-wss
  sleep 3

  systemctl is-active --quiet backhaul-wss || { echo "[x] backhaul-wss did not stay active." >&2; exit 9; }

  cat > "$PHASE2_MARKER" <<EOF
role=foreign
domain=$DOMAIN
control_path=$CONTROL_PATH
tunnel_path=$TUNNEL_PATH
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 0600 "$PHASE2_MARKER"

  echo "[+] Phase 2 Foreign client configured with per-install secret WSS paths."
  echo "[i] Run tunnel-diagnose --deep on Iran to verify WSSMux end-to-end health and throughput."
fi

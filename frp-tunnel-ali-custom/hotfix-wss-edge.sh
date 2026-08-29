#!/usr/bin/env bash
set -Eeuo pipefail

APP="frp-tunnel-ali"
ETC="/etc/${APP}"
STATE="/var/lib/${APP}"
OPT="/opt/${APP}"
BIN="${OPT}/bin"
SERVICE="${APP}.service"
NGINX_CONF="/etc/nginx/conf.d/${APP}.conf"

R=$'\033[0m'; G=$'\033[32m'; Y=$'\033[33m'; RED=$'\033[31m'; C=$'\033[36m'
die(){ echo "${RED}ERROR:${R} $*" >&2; exit 1; }
info(){ echo "${C}::${R} $*"; }
ok(){ echo "${G}OK${R}  $*"; }
warn(){ echo "${Y}!!${R}  $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."
[[ -r "$ETC/meta.env" ]] || die "Missing $ETC/meta.env; install v0.2.0-rc1 first."
# shellcheck disable=SC1090,SC1091
source "$ETC/meta.env"

ROLE="${ROLE,,}"
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || die "Unknown role in meta.env: ${ROLE:-empty}"

if [[ "$ROLE" == "foreign" ]]; then
  info "Foreign node needs no config rewrite. Restarting frpc after the Iran WSS edge is fixed..."
  systemctl restart "$SERVICE"
  sleep 3
  if command -v frp-tunnel >/dev/null 2>&1; then
    set +e
    frp-tunnel health
    rc=$?
    set -e
    exit "$rc"
  fi
  exit 0
fi

: "${IRAN_IP:?missing IRAN_IP}"
: "${DOMAIN:?missing DOMAIN}"
: "${CONTROL_PORT:?missing CONTROL_PORT}"
: "${TLS_CERT:?missing TLS_CERT}"
: "${TLS_KEY:?missing TLS_KEY}"

[[ -r "$TLS_CERT" ]] || die "Certificate not readable: $TLS_CERT"
[[ -r "$TLS_KEY" ]] || die "Private key not readable: $TLS_KEY"
[[ -r "$ETC/frps.toml" ]] || die "Missing $ETC/frps.toml"
[[ -x "$BIN/frps" ]] || die "Missing $BIN/frps"

choose_backend_port() {
  local candidate p
  candidate=$((10#$CONTROL_PORT + 10000))
  if ((candidate > 65535)); then candidate=$((10#$CONTROL_PORT - 10000)); fi
  if ((candidate >= 1024)) && ! ss -H -ltn "sport = :$candidate" 2>/dev/null | grep -q .; then
    echo "$candidate"
    return 0
  fi
  for p in $(seq 18080 18180); do
    if ! ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# Idempotent recovery: if a previous hotfix run already moved FRPS to loopback,
# reuse that backend port instead of allocating another one.
CURRENT_BIND_ADDR="$(sed -n 's/^[[:space:]]*bindAddr[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ETC/frps.toml" | head -n1)"
CURRENT_BIND_PORT="$(sed -n 's/^[[:space:]]*bindPort[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$ETC/frps.toml" | head -n1)"

BACKEND_PORT="${FRPS_BACKEND_PORT:-}"
if ! [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || ((10#$BACKEND_PORT < 1 || 10#$BACKEND_PORT > 65535)); then
  if [[ "$CURRENT_BIND_ADDR" == "127.0.0.1" && "$CURRENT_BIND_PORT" =~ ^[0-9]+$ && "$CURRENT_BIND_PORT" != "$CONTROL_PORT" ]]; then
    BACKEND_PORT="$CURRENT_BIND_PORT"
    info "Detected existing loopback FRPS backend on 127.0.0.1:${BACKEND_PORT}; reusing it."
  else
    BACKEND_PORT="$(choose_backend_port)" || die "Could not find a free loopback backend port."
  fi
fi
[[ "$BACKEND_PORT" != "$CONTROL_PORT" ]] || die "Backend port must differ from public WSS control port."

mkdir -p "$STATE/backups"
chmod 0700 "$STATE" "$STATE/backups"
ts="$(date +%Y%m%d-%H%M%S)"
cp -a "$ETC/frps.toml" "$STATE/backups/frps-before-wss-edge-${ts}.toml"
chmod 0600 "$STATE/backups/frps-before-wss-edge-${ts}.toml"

info "Installing nginx as the TLS/WSS edge. FRPS will be loopback-only on 127.0.0.1:${BACKEND_PORT}."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y nginx >/dev/null
rm -f /etc/nginx/sites-enabled/default

TMP_CFG="$(mktemp)"
trap 'rm -f "$TMP_CFG"' EXIT
awk -v bp="$BACKEND_PORT" '
  /^bindAddr[[:space:]]*=/ { print "bindAddr = \"127.0.0.1\""; next }
  /^bindPort[[:space:]]*=/ { print "bindPort = " bp; next }
  /^transport\.tls\.(force|certFile|keyFile)[[:space:]]*=/ { next }
  { print }
' "$ETC/frps.toml" >"$TMP_CFG"

"$BIN/frps" verify -c "$TMP_CFG" >/dev/null || die "Rewritten frps config failed validation."
install -m 0600 "$TMP_CFG" "$ETC/frps.toml"

cat >"$NGINX_CONF" <<EOF
# FRP Tunnel — Ali Tavazoei Custom Version
# Standard WSS architecture: TLS terminates here, then plaintext WebSocket is
# forwarded over loopback to FRPS. The FRP backend is never exposed publicly.
server {
    listen ${IRAN_IP}:${CONTROL_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:FRPALI:10m;
    ssl_session_timeout 1d;
    server_tokens off;

    location = /~!frp {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        return 404;
    }
}
EOF
chmod 0644 "$NGINX_CONF"
nginx -t >/dev/null || die "nginx configuration validation failed."

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >"/etc/letsencrypt/renewal-hooks/deploy/${APP}-nginx" <<'EOF'
#!/usr/bin/env bash
set -e
systemctl reload nginx
EOF
chmod 0755 "/etc/letsencrypt/renewal-hooks/deploy/${APP}-nginx"

systemctl stop "$SERVICE"
systemctl restart "$SERVICE"
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

systemctl is-active --quiet "$SERVICE" || die "FRPS failed after WSS-edge rewrite."
systemctl is-active --quiet nginx || die "nginx WSS edge failed to start."

sed -i '/^EDGE_PROXY=/d;/^FRPS_BACKEND_PORT=/d' "$ETC/meta.env"
printf 'EDGE_PROXY=%q\nFRPS_BACKEND_PORT=%q\n' "nginx" "$BACKEND_PORT" >>"$ETC/meta.env"
chmod 0600 "$ETC/meta.env"

openssl s_client -connect "${IRAN_IP}:${CONTROL_PORT}" -servername "$DOMAIN" \
  -CAfile /etc/ssl/certs/ca-certificates.crt -verify_return_error </dev/null >/dev/null 2>&1 ||
  die "Public TLS verification failed after nginx edge start."

# FRP's websocket client sends Origin: http://<host>. The x/net/websocket server
# rejects a handshake with a null Origin, so the probe must mirror FRPC.
WS_OUT="$(
  printf 'GET /~!frp HTTP/1.1\r\nHost: %s\r\nOrigin: http://%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' "$DOMAIN" "$DOMAIN" |
    timeout 5 openssl s_client -quiet -connect "${IRAN_IP}:${CONTROL_PORT}" -servername "$DOMAIN" 2>/dev/null || true
)"
grep -q "101 Switching Protocols" <<<"$WS_OUT" || {
  echo "$WS_OUT" | head -n 12 >&2
  die "WSS upgrade did not reach FRPS through nginx."
}

ok "Iran WSS edge fixed: ${DOMAIN}:${CONTROL_PORT} -> nginx TLS/WSS -> 127.0.0.1:${BACKEND_PORT} -> frps"
warn "Now restart the Foreign node once: systemctl restart ${SERVICE}"
warn "Then run on Foreign: frp-tunnel health"

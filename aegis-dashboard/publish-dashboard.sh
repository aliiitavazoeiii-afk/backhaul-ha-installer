#!/usr/bin/env bash
set -Eeuo pipefail

REPO='aliiitavazoeiii-afk/backhaul-ha-installer'
APP_PIN='b1ace0282a26be1b8c2eef4f7207c510374e4a87'
PANEL_PIN='91e8efd917894b8a6f8c53492de1e8a6dbda6671'
DOMAIN=''
IRAN_IP=''
APP_DIR='/opt/aegis-dashboard'
PUBLIC_ENV='/etc/aegis-dashboard/public.env'
ROUTE='/usr/local/sbin/aegis-dashboard-public-route'

log(){ printf '[+] %s\n' "$*"; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }
usage(){ echo 'publish-dashboard.sh --domain panel.example.com --iran-ip 1.2.3.4'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2;;
    --iran-ip) IRAN_IP="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'run as root'
[[ -d "$APP_DIR" && -s "$APP_DIR/provision.py" ]] || die 'Aegis Dashboard is not installed'
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die 'invalid domain'
[[ "$IRAN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'invalid Iran IPv4'

# Fail closed before changing packages/config if DNS is not ready.
mapfile -t resolved < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
found=0
for ip in "${resolved[@]:-}"; do [[ "$ip" == "$IRAN_IP" ]] && found=1; done
[[ "$found" -eq 1 ]] || die "$DOMAIN resolves to ${resolved[*]:-nothing}; create A record ${DOMAIN} -> ${IRAN_IP} first"

if ! ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$IRAN_IP"; then
  die "${IRAN_IP} is not assigned to this server"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y nginx haproxy certbot python3 curl ca-certificates openssl >/dev/null
install -d -m 0700 /etc/aegis-dashboard
install -d -m 0755 "$APP_DIR/vendor" /var/www/aegis-panel-acme /usr/local/sbin

# Unknown public :443 listeners are not replaced.
if ss -Hlnpt 2>/dev/null | awk '$4 ~ /:443$/ {print}' | grep -q .; then
  listeners="$(ss -Hlnpt 2>/dev/null | awk '$4 ~ /:443$/ {print}')"
  if ! grep -Eq 'users:\(\("(nginx|haproxy)"' <<<"$listeners"; then
    printf '%s\n' "$listeners" >&2
    die 'public :443 is owned by an unknown service'
  fi
fi

cat > "$PUBLIC_ENV" <<EOF
PANEL_DOMAIN='${DOMAIN}'
PANEL_IRAN_IP='${IRAN_IP}'
EOF
chmod 0600 "$PUBLIC_ENV"

curl -fL --retry 3 "https://raw.githubusercontent.com/${REPO}/${APP_PIN}/aegis-dashboard/app.py" -o "$APP_DIR/app.py"
curl -fL --retry 3 "https://raw.githubusercontent.com/${REPO}/${PANEL_PIN}/aegis-dashboard/public-route.sh" -o "$ROUTE"
curl -fL --retry 3 "https://raw.githubusercontent.com/${REPO}/${PANEL_PIN}/aegis-dashboard/install-aegis-wrapper.sh" -o "$APP_DIR/vendor/install-aegis-single.sh"
python3 -m py_compile "$APP_DIR/app.py" "$APP_DIR/provision.py"
bash -n "$ROUTE"
bash -n "$APP_DIR/vendor/install-aegis-single.sh"
chmod 0644 "$APP_DIR/app.py"
chmod 0755 "$ROUTE" "$APP_DIR/vendor/install-aegis-single.sh"

install -d -m 0755 /etc/systemd/system/aegis-dashboard.service.d
cat > /etc/systemd/system/aegis-dashboard.service.d/public-origin.conf <<EOF
[Service]
Environment=AEGIS_PUBLIC_ORIGIN=https://${DOMAIN}
EOF

# Rotate the dashboard token because the previous token may have been exposed during bootstrap.
python3 - <<'PY'
import secrets
from pathlib import Path
p=Path('/etc/aegis-dashboard/token')
p.write_text(secrets.token_urlsafe(32)+'\n')
p.chmod(0o600)
PY

# HTTP-only ACME config. The route helper replaces this with the final HTTPS config.
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/conf.d/aegis-dashboard-public.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/aegis-panel-acme;
        default_type text/plain;
    }
    location / { return 404; }
}
EOF
nginx -t >/dev/null
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

if [[ ! -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" || ! -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
  certbot certonly --webroot -w /var/www/aegis-panel-acme -d "$DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive
fi

cat > /etc/letsencrypt/renewal-hooks/deploy/aegis-dashboard-public <<EOF
#!/usr/bin/env bash
${ROUTE}
EOF
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/aegis-dashboard-public

systemctl daemon-reload
systemctl restart aegis-dashboard
"$ROUTE"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null || true
  ufw allow 443/tcp >/dev/null || true
fi

sleep 2
systemctl is-active --quiet aegis-dashboard || die 'dashboard service is not active'
code="$(curl -ksS --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' --max-time 5 "https://${DOMAIN}/" || true)"
[[ "$code" == '403' ]] || die "HTTPS auth probe returned ${code:-none}, expected 403"
TOKEN="$(cat /etc/aegis-dashboard/token)"
log "Dashboard is published securely at https://${DOMAIN}"
printf '\nOpen once to authenticate:\n  https://%s/?token=%s\n\n' "$DOMAIN" "$TOKEN"
printf 'After the redirect, the token disappears from the active URL and is kept in a Secure HttpOnly cookie.\n'
printf 'The dashboard backend itself remains bound only to 127.0.0.1:8787.\n'

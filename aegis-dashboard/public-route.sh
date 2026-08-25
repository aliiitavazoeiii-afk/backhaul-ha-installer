#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE='/etc/aegis-dashboard/public.env'
NGINX_CONF='/etc/nginx/conf.d/aegis-dashboard-public.conf'
HAPROXY_CFG='/etc/haproxy/haproxy.cfg'
BACKUP_ROOT='/root/aegis-dashboard-backups'

log(){ printf '[panel-route] %s\n' "$*"; }
die(){ printf '[panel-route][FAIL] %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'run as root'
[[ -s "$ENV_FILE" ]] || die "$ENV_FILE is missing"

getv(){ sed -n "s/^${1}='\([^']*\)'$/\1/p" "$ENV_FILE" | head -n1; }
DOMAIN="$(getv PANEL_DOMAIN)"
IRAN_IP="$(getv PANEL_IRAN_IP)"
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die 'invalid PANEL_DOMAIN'
[[ "$IRAN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'invalid PANEL_IRAN_IP'
CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
[[ -s "$CERT" && -s "$KEY" ]] || die "certificate for ${DOMAIN} is missing"
command -v nginx >/dev/null || die 'nginx is not installed'

MODE='direct'
if [[ -s /etc/aegis-single/state.env ]]; then MODE='aegis'; fi
TLS_LISTEN='443 ssl'
if [[ "$MODE" == 'aegis' ]]; then TLS_LISTEN='127.0.0.1:9444 ssl'; fi

install -d -m 0755 /var/www/aegis-panel-acme
cat > "$NGINX_CONF.tmp" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/aegis-panel-acme;
        default_type text/plain;
    }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen ${TLS_LISTEN};
    server_name ${DOMAIN};

    ssl_certificate ${CERT};
    ssl_certificate_key ${KEY};
    ssl_protocols TLSv1.2 TLSv1.3;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_pass http://127.0.0.1:8787;
    }
}
EOF
nginx -t -c /etc/nginx/nginx.conf >/dev/null
mv -f "$NGINX_CONF.tmp" "$NGINX_CONF"
nginx -t >/dev/null

if [[ "$MODE" == 'aegis' ]]; then
    command -v haproxy >/dev/null || die 'Aegis state exists but haproxy is not installed'
    [[ -s "$HAPROXY_CFG" ]] || die 'Aegis state exists but haproxy.cfg is missing'
    stamp="$(date +%Y%m%d-%H%M%S)"
    install -d -m 0700 "$BACKUP_ROOT/$stamp"
    cp -a "$HAPROXY_CFG" "$BACKUP_ROOT/$stamp/haproxy.cfg.before-panel-route"
    PANEL_DOMAIN="$DOMAIN" python3 - <<'PY'
import os
from pathlib import Path
p=Path('/etc/haproxy/haproxy.cfg')
text=p.read_text()
domain=os.environ['PANEL_DOMAIN']
lines=text.splitlines()
out=[]
skip=False
for line in lines:
    if line.strip() in {'# BEGIN AEGIS_DASHBOARD_PANEL','# BEGIN AEGIS_DASHBOARD_BACKEND'}:
        skip=True
        continue
    if line.strip() in {'# END AEGIS_DASHBOARD_PANEL','# END AEGIS_DASHBOARD_BACKEND'}:
        skip=False
        continue
    if not skip:
        out.append(line)
lines=out
insert=None
for i,line in enumerate(lines):
    if line.startswith('    acl aegis_carrier ') or line.strip()=='default_backend user_gateway':
        insert=i
        break
if insert is None:
    raise SystemExit('cannot find Aegis frontend insertion point')
front=[
    '    # BEGIN AEGIS_DASHBOARD_PANEL',
    f'    acl dashboard_panel req.ssl_sni -i {domain}',
    '    use_backend dashboard_panel_tls if dashboard_panel',
    '    # END AEGIS_DASHBOARD_PANEL',
]
lines[insert:insert]=front
lines.extend([
    '',
    '# BEGIN AEGIS_DASHBOARD_BACKEND',
    'backend dashboard_panel_tls',
    '    mode tcp',
    '    server dashboard_nginx 127.0.0.1:9444 check inter 2s fall 2 rise 2',
    '# END AEGIS_DASHBOARD_BACKEND',
])
Path('/etc/haproxy/haproxy.cfg.panel-new').write_text('\n'.join(lines)+'\n')
PY
    haproxy -c -f /etc/haproxy/haproxy.cfg.panel-new >/dev/null
    mv -f /etc/haproxy/haproxy.cfg.panel-new "$HAPROXY_CFG"
fi

systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
if [[ "$MODE" == 'aegis' ]]; then
    systemctl enable haproxy >/dev/null 2>&1 || true
    systemctl restart haproxy
fi
log "public dashboard route applied: https://${DOMAIN} (${MODE} mode)"

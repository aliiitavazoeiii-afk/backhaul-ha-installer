#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-}"
BASE_COMMIT="44bf91a05897aca624614fabb6528453a146daa1"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${BASE_COMMIT}/frp-classic443-hardened/install.sh"

log(){ echo "[+] $*"; }
die(){ echo "[x] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || die "Usage: $0 {iran|foreign}"

# The immutable BASE_COMMIT contains the field-tested Classic443 Mux-v4 Final
# profile. This wrapper only improves fresh-install preflight so package-default
# nginx/haproxy left behind by an old uninstall are not mistaken for unrelated
# production services.

safe_stop_stock_haproxy(){
  systemctl is-active --quiet haproxy 2>/dev/null || return 0

  # Never stop HAProxy if it owns any TCP listener.
  if ss -Hlnpt 2>/dev/null | grep -q 'users:(("haproxy"'; then
    die "HAProxy has live listeners; refusing to stop/overwrite it"
  fi

  # Debian/Ubuntu stock config has no frontend/listen/backend sections.
  if [[ -f /etc/haproxy/haproxy.cfg ]] && \
     grep -Eq '^[[:space:]]*(frontend|listen|backend)[[:space:]]+' /etc/haproxy/haproxy.cfg; then
    die "HAProxy has application routing sections; refusing to overwrite it"
  fi

  log "HAProxy is active but idle/stock; stopping it safely for Classic443 install"
  systemctl stop haproxy
}

safe_stop_stock_nginx(){
  systemctl is-active --quiet nginx 2>/dev/null || return 0

  # Any active conf.d vhost means nginx may be serving something unrelated.
  if find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf' -print -quit 2>/dev/null | grep -q .; then
    die "Nginx has active conf.d vhosts; refusing to stop/overwrite it"
  fi

  # sites-enabled/default is safe; any other enabled site is not.
  if find /etc/nginx/sites-enabled -maxdepth 1 -type f ! -name default -print -quit 2>/dev/null | grep -q .; then
    die "Nginx has enabled non-default sites; refusing to stop/overwrite it"
  fi

  # A stock nginx may listen on :80. Any other listener is treated as unrelated.
  if ss -Hlnpt 2>/dev/null | grep 'users:(("nginx"' | awk '{print $4}' | grep -Ev '(^|:)80$' | grep -q .; then
    die "Nginx has non-default live listeners; refusing to stop/overwrite it"
  fi

  log "Nginx is active but stock/default; stopping it safely for Classic443 install"
  systemctl stop nginx
}

if [[ "$ROLE" == iran ]]; then
  safe_stop_stock_haproxy
  safe_stop_stock_nginx
fi

exec bash <(curl -fsSL --retry 4 "$BASE_URL") "$ROLE"

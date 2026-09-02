#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/tunnel-cleanup-backup-${STAMP}"
mkdir -p "$BACKUP"
chmod 0700 "$BACKUP"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }

say(){ printf '\n==> %s\n' "$*"; }
warn(){ printf 'WARN: %s\n' "$*" >&2; }

backup_path(){
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  local safe="${p#/}"
  mkdir -p "$BACKUP/$(dirname "$safe")"
  cp -a "$p" "$BACKUP/$safe"
}

stop_matching_units(){
  local patterns=(
    'frp-tunnel-ali.service'
    'frp-tunnel-ali-shard@*.service'
    'frp-tunnel-ali-refresh.service'
    'frp-tunnel-ali-refresh.timer'
    'frp-tunnel-ali-pro.service'
    'frp-tunnel-ali-pro-shard@*.service'
    'aegis-client.service'
    'aegis-client-extra.service'
    'aegis-client-extra2.service'
    'aegis-server.service'
    'aegis-single.service'
    'backhaul-stealth*.service'
    'backhaul-ha*.service'
  )
  local pat unit
  for pat in "${patterns[@]}"; do
    while read -r unit; do
      [[ -n "$unit" ]] || continue
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done < <(systemctl list-unit-files --type=service --type=timer --no-legend 2>/dev/null | awk '{print $1}' | grep -E "^${pat//\*/.*}$" || true)
  done
}

say "Backing up known tunnel configuration"
for p in \
  /etc/frp-tunnel-ali /opt/frp-tunnel-ali /var/lib/frp-tunnel-ali \
  /etc/frp-tunnel-ali-pro /opt/frp-tunnel-ali-pro /var/lib/frp-tunnel-ali-pro \
  /etc/aegis-single /opt/aegis-single /var/lib/aegis-single \
  /etc/backhaul-stealth /opt/backhaul-stealth /var/lib/backhaul-stealth \
  /etc/haproxy/haproxy.cfg \
  /etc/nginx/nginx.conf; do
  backup_path "$p"
done

for p in /etc/nginx/conf.d/frp-tunnel-ali*.conf /etc/nginx/conf.d/*aegis*.conf /etc/nginx/sites-enabled/*frp* /etc/nginx/sites-enabled/*aegis*; do
  [[ -e "$p" || -L "$p" ]] && backup_path "$p"
done

say "Stopping known FRP/Aegis/Backhaul tunnel services"
stop_matching_units

say "Handling HAProxy only when it is clearly part of the old tunnel"
if systemctl is-active --quiet haproxy 2>/dev/null; then
  HAPROXY_TUNNEL=0
  if [[ -r /etc/haproxy/haproxy.cfg ]] && grep -Eqi 'aegis|frp|backhaul|user_gateway|vpn_users|10443|10444|1500[0-9]|1501[0-9]' /etc/haproxy/haproxy.cfg; then
    HAPROXY_TUNNEL=1
  fi
  if ss -H -lntp 'sport = :443' 2>/dev/null | grep -q 'haproxy' && [[ -r /etc/haproxy/haproxy.cfg ]] && grep -Eq '(^|[^0-9])443([^0-9]|$)' /etc/haproxy/haproxy.cfg; then
    HAPROXY_TUNNEL=1
  fi

  if [[ "$HAPROXY_TUNNEL" == 1 ]]; then
    systemctl disable --now haproxy >/dev/null 2>&1 || true
    echo "Stopped/disabled HAProxy because its config matches the old tunnel."
  else
    warn "HAProxy is active but did not match known tunnel markers; it was preserved."
  fi
fi

say "Removing known project units and runtime files"
rm -f \
  /etc/systemd/system/frp-tunnel-ali.service \
  /etc/systemd/system/frp-tunnel-ali-shard@.service \
  /etc/systemd/system/frp-tunnel-ali-refresh.service \
  /etc/systemd/system/frp-tunnel-ali-refresh.timer \
  /etc/systemd/system/frp-tunnel-ali-pro.service \
  /etc/systemd/system/frp-tunnel-ali-pro-shard@.service \
  /etc/systemd/system/aegis-client.service \
  /etc/systemd/system/aegis-client-extra.service \
  /etc/systemd/system/aegis-client-extra2.service \
  /etc/systemd/system/aegis-server.service \
  /etc/systemd/system/aegis-single.service \
  /usr/local/bin/frp-tunnel \
  /usr/local/bin/frp-ali-health \
  /usr/local/sbin/frp-tunnel-ali-refresh-next-shard \
  /etc/systemd/system/nginx.service.d/frp-capacity.conf \
  /etc/systemd/system/nginx.service.d/frp-tunnel-ali-pro-limits.conf

rm -rf \
  /etc/frp-tunnel-ali /opt/frp-tunnel-ali /var/lib/frp-tunnel-ali \
  /etc/frp-tunnel-ali-pro /opt/frp-tunnel-ali-pro /var/lib/frp-tunnel-ali-pro \
  /etc/aegis-single /opt/aegis-single /var/lib/aegis-single \
  /etc/backhaul-stealth /opt/backhaul-stealth /var/lib/backhaul-stealth

say "Removing only tunnel-specific nginx virtual-host files"
rm -f /etc/nginx/conf.d/frp-tunnel-ali*.conf /etc/nginx/conf.d/*aegis*.conf
rm -f /etc/nginx/sites-enabled/*frp* /etc/nginx/sites-enabled/*aegis*

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx || true
  else
    warn "nginx config is not valid after removing old tunnel vhosts; nginx was NOT restarted. Backup: $BACKUP"
  fi
fi

say "Preserving Xray/3x-ui"
for u in xray x-ui 3x-ui; do
  if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "${u}.service"; then
    printf '%-12s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"
  fi
done

say "Port ownership after cleanup"
ss -lntp 2>/dev/null | grep -E ':(443|8443|18443|10443|10444|9443)([^0-9]|$)' || true

if ss -H -lntp 'sport = :443' 2>/dev/null | grep -q .; then
  echo
  warn "TCP/443 is still occupied by a service that was not safely identified as an old tunnel component:"
  ss -H -lntp 'sport = :443' 2>/dev/null || true
  warn "Ali Pro installation will intentionally refuse to take over that port automatically."
  echo "Backup saved at: $BACKUP"
  exit 2
fi

echo
echo "CLEANUP COMPLETE"
echo "Backup saved at: $BACKUP"
echo "Xray/3x-ui and Let's Encrypt certificates were preserved."

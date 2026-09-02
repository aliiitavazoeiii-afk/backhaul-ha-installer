#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/frp-nomux
CFG_DIR=/etc/frp-nomux
LOG_DIR=/var/log/frp-nomux
FRPCTL=/usr/local/bin/frpctl
NGINX_FRP_CONF=/etc/nginx/conf.d/frp-nomux.conf
NGINX_HOOK=/etc/letsencrypt/renewal-hooks/deploy/frp-nomux-nginx
NGINX_DROPIN=/etc/systemd/system/nginx.service.d/frp-classic443.conf
HAPROXY_DROPIN=/etc/systemd/system/haproxy.service.d/frp-classic443.conf
FRPC_DROPIN_DIR=/etc/systemd/system/frpc-nomux.service.d
FRPS_DROPIN_DIR=/etc/systemd/system/frps-nomux.service.d
SWAPFILE=/swapfile-frp-resilience
SYSCTL_FILE=/etc/sysctl.d/99-frp-resilience.conf

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] run as root' >&2; exit 1; }

is_iran=0
is_foreign=0
[[ -f "$CFG_DIR/frps.toml" || -f /etc/systemd/system/frps-nomux.service ]] && is_iran=1
[[ -f "$CFG_DIR/frpc.toml" || -f /etc/systemd/system/frpc-nomux.service ]] && is_foreign=1

echo '[+] Stopping FRP Classic443 services...'
systemctl disable --now frpc-nomux.service 2>/dev/null || true
systemctl disable --now frps-nomux.service 2>/dev/null || true
rm -f /etc/systemd/system/frpc-nomux.service /etc/systemd/system/frps-nomux.service
rm -rf "$FRPC_DROPIN_DIR" "$FRPS_DROPIN_DIR"
systemctl daemon-reload
systemctl reset-failed frpc-nomux.service frps-nomux.service 2>/dev/null || true

if (( is_iran )); then
  echo '[+] Cleaning Iran-side routing components...'

  # Remove only the nginx vhost and renewal hook created by this tunnel.
  rm -f "$NGINX_FRP_CONF" "$NGINX_HOOK" "$NGINX_DROPIN"

  # Touch HAProxy only if its current config clearly matches this tunnel layout.
  if [[ -f /etc/haproxy/haproxy.cfg ]] && \
     grep -q '^frontend public_443$' /etc/haproxy/haproxy.cfg && \
     grep -q '^backend frp_carrier_tls$' /etc/haproxy/haproxy.cfg && \
     grep -q '^backend frp_user_gateway$' /etc/haproxy/haproxy.cfg && \
     grep -q '127.0.0.1:9443' /etc/haproxy/haproxy.cfg && \
     grep -q '127.0.0.1:10445' /etc/haproxy/haproxy.cfg; then

    latest_backup="$(find /root -maxdepth 2 -type f -path '/root/frp-nomux-backup-*/haproxy.cfg' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)"

    if [[ -n "$latest_backup" ]] && command -v haproxy >/dev/null 2>&1 && haproxy -c -f "$latest_backup" >/dev/null 2>&1; then
      echo "[+] Restoring previous HAProxy config: $latest_backup"
      cp -a /etc/haproxy/haproxy.cfg "/root/haproxy.frp-classic443-uninstall-$(date +%Y%m%d-%H%M%S).cfg"
      cp -a "$latest_backup" /etc/haproxy/haproxy.cfg
      systemctl restart haproxy 2>/dev/null || true
    else
      echo '[+] Current HAProxy belongs to FRP Classic443; stopping it and preserving its config backup.'
      cp -a /etc/haproxy/haproxy.cfg "/root/haproxy.frp-classic443-uninstall-$(date +%Y%m%d-%H%M%S).cfg"
      systemctl disable --now haproxy.service 2>/dev/null || true
    fi
  else
    echo '[i] HAProxy config does not uniquely match FRP Classic443; leaving it untouched.'
  fi

  rm -f "$HAPROXY_DROPIN"
  systemctl daemon-reload

  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
    else
      echo '[!] nginx -t failed after FRP vhost removal; nginx was NOT restarted.' >&2
    fi
  fi
fi

# Remove project runtime/config/logs and local management helper.
rm -rf "$APP_DIR" "$CFG_DIR" "$LOG_DIR"
rm -f "$FRPCTL" /root/frp-nomux.env

# Remove only the emergency swap file uniquely created by this project.
if swapon --show --noheadings 2>/dev/null | awk '{print $1}' | grep -Fxq "$SWAPFILE"; then
  swapoff "$SWAPFILE" 2>/dev/null || true
fi
if [[ -f /etc/fstab ]]; then
  sed -i '\|^/swapfile-frp-resilience[[:space:]]|d' /etc/fstab
fi
rm -f "$SWAPFILE" "$SYSCTL_FILE"

systemctl daemon-reload

echo
echo '[+] FRP Classic443 removed.'
echo '[i] Preserved intentionally: Xray/3x-ui, Let\x27s Encrypt certificates, nginx/haproxy packages, UFW rules, and nginx capacity tuning in nginx.conf.'

echo
echo '=== REMAINING FRP PROCESSES ==='
ps aux | grep -E '[f]rpc|[f]rps' || echo 'none'
echo '=== IMPORTANT LISTENERS ==='
ss -lntp 2>/dev/null | grep -E ':443|:9443|:18081|:10445' || true

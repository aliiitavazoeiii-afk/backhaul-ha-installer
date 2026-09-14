#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

STATE_DIR="/var/lib/xhttp-dual"
STAMP="$(date +%Y%m%d-%H%M%S)"
PRE_DIR="$STATE_DIR/uninstall-backups/$STAMP"
mkdir -p "$PRE_DIR"
chmod 700 "$STATE_DIR" "$STATE_DIR/uninstall-backups" "$PRE_DIR" 2>/dev/null || true

[[ -d /etc/xhttp-dual ]] && cp -a /etc/xhttp-dual "$PRE_DIR/" || true
[[ -f "$STATE_DIR/state.json" ]] && cp -a "$STATE_DIR/state.json" "$PRE_DIR/state.json" || true
[[ -f /etc/x-ui/x-ui.db ]] && cp -a /etc/x-ui/x-ui.db "$PRE_DIR/x-ui.db" || true

echo "[1/7] Stopping failover controller..."
systemctl disable --now xhttp-dual-controller.service 2>/dev/null || true

if [[ -x /usr/local/bin/xhttp-dual && -f /etc/xhttp-dual/config.json ]]; then
  echo "[2/7] Removing managed x-ui routing/outbounds..."
  /usr/local/bin/xhttp-dual remove-managed || {
    echo "ERROR: managed x-ui cleanup failed. Tunnel files were NOT deleted."
    echo "Backup: $PRE_DIR"
    echo "Inspect: journalctl -u x-ui -n 100 --no-pager"
    exit 1
  }
else
  echo "[2/7] Controller/config incomplete; skipping managed x-ui cleanup."
fi

echo "[3/7] Stopping all dual/vision/redirect services..."
for svc in \
  xhttp-dual-f1.service \
  xhttp-dual-f2.service \
  xhttp-dual-f1-vision.service \
  xhttp-dual-f2-vision.service \
  xhttp-dual-f1-vision-redirect.service \
  xhttp-dual-f2-vision-redirect.service; do
  systemctl disable --now "$svc" 2>/dev/null || true
done

# Explicitly remove any persistent NAT redirect rules by invoking helpers first.
for helper in /opt/xhttp-dual/vision-redirect-f1.sh /opt/xhttp-dual/vision-redirect-f2.sh; do
  [[ -x "$helper" ]] && "$helper" stop 2>/dev/null || true
done

# Defensive cleanup of known localhost redirect rules from migration helpers.
if command -v iptables >/dev/null 2>&1; then
  for old in 11818 11819; do
    for new in 12818 12819; do
      while iptables -w 5 -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport "$old" -j REDIRECT --to-ports "$new" 2>/dev/null; do
        iptables -w 5 -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport "$old" -j REDIRECT --to-ports "$new" || break
      done
      while iptables -w 5 -t nat -C OUTPUT -p udp -d 127.0.0.1 --dport "$old" -j REDIRECT --to-ports "$new" 2>/dev/null; do
        iptables -w 5 -t nat -D OUTPUT -p udp -d 127.0.0.1 --dport "$old" -j REDIRECT --to-ports "$new" || break
      done
    done
  done
fi

pkill -f '/opt/xhttp-dual/xray' 2>/dev/null || true
sleep 1

echo "[4/7] Removing systemd units..."
rm -f \
  /etc/systemd/system/xhttp-dual-controller.service \
  /etc/systemd/system/xhttp-dual-f1.service \
  /etc/systemd/system/xhttp-dual-f2.service \
  /etc/systemd/system/xhttp-dual-f1-vision.service \
  /etc/systemd/system/xhttp-dual-f2-vision.service \
  /etc/systemd/system/xhttp-dual-f1-vision-redirect.service \
  /etc/systemd/system/xhttp-dual-f2-vision-redirect.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "[5/7] Removing project files..."
rm -f \
  /usr/local/bin/xhttp-dual \
  /usr/local/bin/xhttp-dual-replace \
  /usr/local/bin/xhttp-dual-replace-vision \
  /usr/local/bin/xhttp-dual-reset
rm -rf /opt/xhttp-dual
rm -rf /etc/xhttp-dual
rm -f /etc/sysctl.d/99-xhttp-dual-bbr.conf
sysctl --system >/dev/null 2>&1 || true

echo "[6/7] Preserving backups..."
mkdir -p "$STATE_DIR"
cat >"$STATE_DIR/UNINSTALLED.txt" <<EOF
Uninstalled at $(date -Is)
Pre-uninstall snapshot: $PRE_DIR
Existing backups under $STATE_DIR are intentionally preserved.
Delete $STATE_DIR manually only when rollback is no longer needed.
EOF

echo "[7/7] Verification..."
LEFT=0
if ss -lntup 2>/dev/null | grep -E ':(11818|11819|12818|12819)\b'; then
  echo "WARNING: a process still uses a dual/vision SOCKS port."
  LEFT=1
else
  echo "Dual/Vision SOCKS ports are free."
fi

if command -v iptables >/dev/null 2>&1 && iptables -t nat -S OUTPUT 2>/dev/null | grep -E -- '--dport (11818|11819).*REDIRECT.*(12818|12819)'; then
  echo "WARNING: a migration REDIRECT rule still exists."
  LEFT=1
else
  echo "Migration REDIRECT rules: none."
fi

systemctl is-active --quiet x-ui && echo "x-ui: active" || echo "WARNING: x-ui is not active"

echo
echo "Dual Vision/XHTTP compatibility stack removed from Iran."
echo "x-ui itself and its VLESS users were NOT deleted."
echo "Pre-uninstall backup: $PRE_DIR"

(( LEFT == 0 )) || exit 1

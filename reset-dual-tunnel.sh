#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="${1:-all}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f /etc/xhttp-dual/config.json ]] || { echo "XHTTP Dual is not installed."; exit 1; }

case "$TARGET" in
  all) NODES=(f1 f2) ;;
  f1)  NODES=(f1) ;;
  f2)  NODES=(f2) ;;
  *) echo "Usage: xhttp-dual-reset [all|f1|f2]"; exit 1 ;;
esac

controller_was_active=0
if systemctl is-active --quiet xhttp-dual-controller.service; then
  controller_was_active=1
fi

restore_controller() {
  if (( controller_was_active == 1 )); then
    systemctl start xhttp-dual-controller.service 2>/dev/null || true
  fi
}
trap restore_controller EXIT

# Freeze health-state changes during the short tunnel restart. x-ui itself is
# intentionally NOT restarted, so the routing rules remain loaded.
systemctl stop xhttp-dual-controller.service 2>/dev/null || true

echo "Resetting: ${NODES[*]}"
for node in "${NODES[@]}"; do
  svc="xhttp-dual-${node}.service"
  systemctl restart "$svc"
done

sleep 2

for node in "${NODES[@]}"; do
  svc="xhttp-dual-${node}.service"
  systemctl is-active --quiet "$svc" || { echo "$svc failed to start"; exit 1; }

  if [[ "$node" == "f1" ]]; then port=11818; else port=11819; fi
  ss -lntH "( sport = :${port} )" | grep -q . || { echo "SOCKS ${port} is not listening"; exit 1; }

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 --connect-timeout 5 \
    --socks5-hostname "127.0.0.1:${port}" https://cp.cloudflare.com/generate_204 || true)"
  if [[ "$code" == "204" || "$code" == "200" ]]; then
    echo "${node^^}: tunnel OK (HTTP ${code})"
  else
    echo "${node^^}: tunnel test FAILED (HTTP ${code:-000})"
  fi
done

if (( controller_was_active == 1 )); then
  systemctl start xhttp-dual-controller.service
fi
trap - EXIT

sleep 2

echo
if command -v xhttp-dual >/dev/null 2>&1; then
  xhttp-dual status || true
else
  systemctl status xhttp-dual-f1 xhttp-dual-f2 --no-pager || true
fi

echo
echo "Tunnel reset complete. x-ui was NOT restarted."

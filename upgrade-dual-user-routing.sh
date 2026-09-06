#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-dual-sticky-failover"
INSTALL_DIR="/opt/xhttp-dual"
V2="$INSTALL_DIR/controller-v2.py"
CLI="/usr/local/bin/xhttp-dual"
SERVICE="/etc/systemd/system/xhttp-dual-controller.service"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f "$INSTALL_DIR/controller.py" ]] || { echo "Missing base controller: $INSTALL_DIR/controller.py"; exit 1; }
[[ -f /etc/xhttp-dual/config.json ]] || { echo "Missing /etc/xhttp-dual/config.json"; exit 1; }

curl -fsSL "$BASE_URL/dual-controller-v2.py" -o "$V2"
chmod 0755 "$V2"
python3 -m py_compile "$V2"

systemctl stop xhttp-dual-controller.service 2>/dev/null || true

cat >"$CLI" <<'EOF'
#!/usr/bin/env bash
set -o pipefail
CONTROLLER="/opt/xhttp-dual/controller-v2.py"
PYTHON="/usr/bin/python3"
if [[ ! -f "$CONTROLLER" ]]; then
  echo "xhttp-dual controller not found: $CONTROLLER" >&2
  exit 1
fi
if [[ "${1:-}" == "status" ]]; then
  "$PYTHON" "$CONTROLLER" "$@" | awk '
  BEGIN { green="\033[1;32m"; red="\033[1;31m"; yellow="\033[1;33m"; reset="\033[0m" }
  {
    gsub(/healthy=True/,  "healthy=" green "True" reset)
    gsub(/healthy=False/, "healthy=" red "False" reset)
    gsub(/healthy=None/,  "healthy=" yellow "None" reset)
    print
  }'
  exit ${PIPESTATUS[0]}
fi
exec "$PYTHON" "$CONTROLLER" "$@"
EOF
chmod 0755 "$CLI"

if [[ -f "$SERVICE" ]]; then
  cp -a "$SERVICE" "$SERVICE.bak.$(date +%Y%m%d-%H%M%S)"
  sed -i 's#ExecStart=/usr/bin/python3 /opt/xhttp-dual/controller.py daemon#ExecStart=/usr/bin/python3 /opt/xhttp-dual/controller-v2.py daemon#' "$SERVICE"
fi

systemctl daemon-reload

# Rebuild user rules from canonical 3x-ui client tables. This restarts x-ui once.
/usr/bin/python3 "$V2" sync

systemctl enable --now xhttp-dual-controller.service
sleep 2

echo
echo "UPGRADE COMPLETE"
xhttp-dual status
echo
xhttp-dual diagnose

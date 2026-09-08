#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-dual-sticky-failover"
INSTALL_DIR="/opt/xhttp-dual"
V2="$INSTALL_DIR/controller-v2.py"
V3="$INSTALL_DIR/controller-v3.py"
CLI="/usr/local/bin/xhttp-dual"
SERVICE="/etc/systemd/system/xhttp-dual-controller.service"
CONFIG="/etc/xhttp-dual/config.json"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f "$V2" ]] || { echo "Missing controller-v2. Run upgrade-dual-user-routing.sh first."; exit 1; }
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG"; exit 1; }
[[ -f "$SERVICE" ]] || { echo "Missing $SERVICE"; exit 1; }

curl -fsSL "$BASE_URL/dual-controller-v3.py" -o "$V3"
chmod 0755 "$V3"
python3 -m py_compile "$V3"

# Persist the default latency ceiling so it is visible/tunable in config.
python3 - "$CONFIG" <<'PY'
import json, os, sys, tempfile
p = sys.argv[1]
with open(p, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
for node in ('f1', 'f2'):
    cfg.setdefault('nodes', {}).setdefault(node, {}).setdefault('max_latency_ms', 1500)
fd, tmp = tempfile.mkstemp(prefix='.config.', dir=os.path.dirname(p))
os.close(fd)
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, sort_keys=True)
    f.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY

cp -a "$SERVICE" "$SERVICE.bak.$(date +%Y%m%d-%H%M%S)"
sed -i -E 's#ExecStart=/usr/bin/python3 /opt/xhttp-dual/controller(-v2)?\.py daemon#ExecStart=/usr/bin/python3 /opt/xhttp-dual/controller-v3.py daemon#' "$SERVICE"

cat >"$CLI" <<'EOF'
#!/usr/bin/env bash
set -o pipefail
CONTROLLER="/opt/xhttp-dual/controller-v3.py"
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

systemctl daemon-reload
systemctl restart xhttp-dual-controller.service
sleep 2

echo
echo "LATENCY HEALTH UPGRADE COMPLETE"
echo "Default quarantine limit: 1500 ms end-to-end through each XHTTP tunnel"
echo "3 consecutive slow/failed checks => unhealthy; 5 good checks => recovered"
echo "This upgrade did NOT restart x-ui."
echo
xhttp-dual status

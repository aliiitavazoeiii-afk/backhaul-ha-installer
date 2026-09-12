#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_REF="${PROJECT_REF:-xhttp-dual-sticky-failover}"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${PROJECT_REF}"
INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
SERVICE="xhttp-dual-controller.service"
DROPIN_DIR="/etc/systemd/system/${SERVICE}.d"
DROPIN="$DROPIN_DIR/10-v4-hardening.conf"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
for f in "$INSTALL_DIR/controller-v3.py" "$CONFIG_DIR/config.json"; do
  [[ -f "$f" ]] || { echo "Missing current v3 installation file: $f"; exit 1; }
done
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$STATE_DIR/hardening-backups/$STAMP"
mkdir -p "$BACKUP_DIR"
chmod 700 "$STATE_DIR" "$STATE_DIR/hardening-backups" "$BACKUP_DIR" 2>/dev/null || true

echo "[1/7] Fetching v4 controller and live SNI helper from ref: $PROJECT_REF"
curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 \
  "$BASE_URL/dual-controller-v4.py" -o "$TMP/controller-v4.py"
curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 \
  "$BASE_URL/set-xhttp-node-sni.sh" -o "$TMP/set-xhttp-node-sni.sh"
python3 -m py_compile "$TMP/controller-v4.py"
bash -n "$TMP/set-xhttp-node-sni.sh"

echo "[2/7] Backing up current controller/config/CLI..."
cp -a "$CONFIG_DIR/config.json" "$BACKUP_DIR/config.json"
cp -a "$INSTALL_DIR/controller-v3.py" "$BACKUP_DIR/controller-v3.py"
[[ -f "$INSTALL_DIR/controller-v4.py" ]] && cp -a "$INSTALL_DIR/controller-v4.py" "$BACKUP_DIR/controller-v4.py.old"
[[ -f /usr/local/bin/xhttp-dual ]] && cp -a /usr/local/bin/xhttp-dual "$BACKUP_DIR/xhttp-dual"
[[ -f /usr/local/bin/xhttp-dual-set-sni ]] && cp -a /usr/local/bin/xhttp-dual-set-sni "$BACKUP_DIR/xhttp-dual-set-sni.old"
if [[ -f "$DROPIN" ]]; then
  cp -a "$DROPIN" "$BACKUP_DIR/10-v4-hardening.conf.old"
fi

echo "[3/7] Adding jitter, target diversity, and Foreign TCP metadata..."
python3 - "$CONFIG_DIR/config.json" "$CONFIG_DIR/foreign1.env" "$CONFIG_DIR/foreign2.env" "$TMP/config.json" <<'PY'
import ast, json, sys
cfg_path, env1, env2, out_path = sys.argv[1:]

def env_port(path):
    try:
        for line in open(path):
            if line.startswith("PORT="):
                raw = line.split("=", 1)[1].strip()
                try:
                    return int(ast.literal_eval(raw))
                except Exception:
                    return int(raw.strip("'\""))
    except FileNotFoundError:
        pass
    return 443

with open(cfg_path) as f:
    cfg = json.load(f)

cfg["check_jitter_ratio"] = 0.30
secondary = "https://connectivitycheck.gstatic.com/generate_204"
for idx, node in enumerate(("f1", "f2")):
    nc = cfg.setdefault("nodes", {}).setdefault(node, {})
    primary = str(nc.get("health_url") or "https://cp.cloudflare.com/generate_204")
    urls = nc.get("health_urls")
    if not isinstance(urls, list):
        urls = []
    merged = []
    for url in [primary] + urls + [secondary]:
        url = str(url).strip()
        if url and url not in merged:
            merged.append(url)
    nc["health_url"] = primary
    nc["health_urls"] = merged
    nc["foreign_port"] = env_port(env1 if idx == 0 else env2)
    nc.setdefault("max_latency_ms", 1500)

cfg.setdefault("slow_failure_threshold", 2)
with open(out_path, "w") as f:
    json.dump(cfg, f, indent=2, sort_keys=True)
    f.write("\n")
PY
python3 -m json.tool "$TMP/config.json" >/dev/null

rollback() {
  echo
  echo "Hardening upgrade failed; rolling back controller/config/CLI..."
  cp -a "$BACKUP_DIR/config.json" "$CONFIG_DIR/config.json" || true
  if [[ -f "$BACKUP_DIR/controller-v4.py.old" ]]; then
    cp -a "$BACKUP_DIR/controller-v4.py.old" "$INSTALL_DIR/controller-v4.py" || true
  else
    rm -f "$INSTALL_DIR/controller-v4.py"
  fi
  if [[ -f "$BACKUP_DIR/xhttp-dual" ]]; then
    cp -a "$BACKUP_DIR/xhttp-dual" /usr/local/bin/xhttp-dual || true
  fi
  if [[ -f "$BACKUP_DIR/xhttp-dual-set-sni.old" ]]; then
    cp -a "$BACKUP_DIR/xhttp-dual-set-sni.old" /usr/local/bin/xhttp-dual-set-sni || true
  else
    rm -f /usr/local/bin/xhttp-dual-set-sni
  fi
  if [[ -f "$BACKUP_DIR/10-v4-hardening.conf.old" ]]; then
    mkdir -p "$DROPIN_DIR"
    cp -a "$BACKUP_DIR/10-v4-hardening.conf.old" "$DROPIN"
  else
    rm -f "$DROPIN"
  fi
  systemctl daemon-reload || true
  systemctl restart "$SERVICE" || true
  echo "Rollback backup: $BACKUP_DIR"
}
trap rollback ERR

install -m 0600 "$TMP/config.json" "$CONFIG_DIR/config.json"
install -m 0755 "$TMP/controller-v4.py" "$INSTALL_DIR/controller-v4.py"
install -m 0755 "$TMP/set-xhttp-node-sni.sh" /usr/local/bin/xhttp-dual-set-sni

echo "[4/7] Switching controller service and CLI to v4..."
mkdir -p "$DROPIN_DIR"
cat >"$DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/python3 $INSTALL_DIR/controller-v4.py daemon
EOF

cat >/usr/local/bin/xhttp-dual <<'EOF'
#!/bin/sh
exec /usr/bin/python3 /opt/xhttp-dual/controller-v4.py "$@"
EOF
chmod 0755 /usr/local/bin/xhttp-dual

echo "[5/7] Restarting ONLY the controller (x-ui is not explicitly restarted)..."
systemctl daemon-reload
systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE"

EXEC_LINE="$(systemctl show -p ExecStart --value "$SERVICE")"
printf '%s\n' "$EXEC_LINE" | grep -q 'controller-v4.py'

echo "[6/7] Runtime verification..."
xhttp-dual status
echo
xhttp-dual diagnose
echo
xhttp-dual netcheck

echo "[7/7] Done."
trap - ERR
echo
echo "============================================================"
echo "XHTTP DUAL V4 HARDENING READY"
echo "Probe timing  : randomized +/-30%"
echo "Health target : primary + fallback target"
echo "Net diagnose  : xhttp-dual netcheck"
echo "SNI updater   : xhttp-dual-set-sni f1|f2 <hostname>"
echo "x-ui action   : NOT explicitly restarted by this upgrade"
echo "Backup        : $BACKUP_DIR"
echo "============================================================"

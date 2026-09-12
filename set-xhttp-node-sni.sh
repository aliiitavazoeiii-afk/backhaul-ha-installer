#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ $# -eq 2 ]] || { echo "Usage: xhttp-dual-set-sni f1|f2 <new-sni>"; exit 2; }

NODE="$1"
NEW_SNI="$2"
case "$NODE" in
  f1) NUM=1 ;;
  f2) NUM=2 ;;
  *) echo "Node must be f1 or f2."; exit 2 ;;
esac

[[ "$NEW_SNI" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid SNI hostname."; exit 2; }
NODE_JSON="$CONFIG_DIR/${NODE}.json"
ENV_FILE="$CONFIG_DIR/foreign${NUM}.env"
SERVICE="xhttp-dual-${NODE}.service"
[[ -x "$INSTALL_DIR/xray" && -f "$NODE_JSON" && -f "$ENV_FILE" ]] || {
  echo "Missing XHTTP Dual files for $NODE."; exit 1;
}

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$STATE_DIR/sni-backups/$STAMP-$NODE"
mkdir -p "$BACKUP_DIR"
chmod 700 "$STATE_DIR" "$STATE_DIR/sni-backups" "$BACKUP_DIR" 2>/dev/null || true
cp -a "$NODE_JSON" "$BACKUP_DIR/${NODE}.json"
cp -a "$ENV_FILE" "$BACKUP_DIR/$(basename "$ENV_FILE")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$NODE_JSON" "$TMP/${NODE}.json" "$NEW_SNI" <<'PY'
import json, sys
src, dst, sni = sys.argv[1:]
with open(src) as f:
    obj = json.load(f)
outs = obj.get("outbounds") or []
if len(outs) != 1:
    raise SystemExit("Unexpected node config: expected exactly one outbound")
rs = outs[0].setdefault("streamSettings", {}).setdefault("realitySettings", {})
rs["serverName"] = sni
with open(dst, "w") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
PY

"$INSTALL_DIR/xray" run -test -c "$TMP/${NODE}.json" >/dev/null

python3 - "$ENV_FILE" "$TMP/$(basename "$ENV_FILE")" "$NEW_SNI" <<'PY'
import sys
src, dst, sni = sys.argv[1:]
lines = open(src).read().splitlines()
out = []
seen = False
for line in lines:
    if line.startswith("SNI="):
        out.append("SNI=" + repr(sni))
        seen = True
    else:
        out.append(line)
if not seen:
    out.append("SNI=" + repr(sni))
open(dst, "w").write("\n".join(out) + "\n")
PY

rollback() {
  echo "SNI update failed; rolling back $NODE..."
  cp -a "$BACKUP_DIR/${NODE}.json" "$NODE_JSON"
  cp -a "$BACKUP_DIR/$(basename "$ENV_FILE")" "$ENV_FILE"
  systemctl restart "$SERVICE" || true
  echo "Rollback: $BACKUP_DIR"
}
trap rollback ERR

install -m 0600 "$TMP/${NODE}.json" "$NODE_JSON"
install -m 0600 "$TMP/$(basename "$ENV_FILE")" "$ENV_FILE"
systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE"

SOCKS_PORT="$(python3 - "$ENV_FILE" <<'PY'
import ast, sys
for line in open(sys.argv[1]):
    if line.startswith("SOCKS_PORT="):
        print(ast.literal_eval(line.split("=",1)[1].strip()))
        break
else:
    raise SystemExit(1)
PY
)"

echo "Testing $NODE with new SNI through 127.0.0.1:$SOCKS_PORT ..."
EGRESS="$(curl -4 -fsS --max-time 20 --connect-timeout 8 \
  --socks5-hostname "127.0.0.1:${SOCKS_PORT}" https://icanhazip.com | tr -d '[:space:]')"
[[ -n "$EGRESS" ]]
trap - ERR

echo
echo "SNI UPDATE OK"
echo "Node      : ${NODE^^}"
echo "New SNI   : $NEW_SNI"
echo "Egress    : $EGRESS"
echo "Backup    : $BACKUP_DIR"
echo "x-ui      : NOT restarted"
echo "Controller: will observe recovery automatically"

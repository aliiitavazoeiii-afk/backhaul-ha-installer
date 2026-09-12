#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-prepare}"
case "$MODE" in prepare|activate|status) ;; *) echo "Usage: $0 prepare|activate|status"; exit 2 ;; esac

XRAY_DIR="/usr/local/lib/xhttp-reality"
CONFIG_DIR="/etc/xhttp-reality"
SERVER_JSON="$CONFIG_DIR/server.json"
CLIENT_ENV="/root/xhttp-reality-client.env"
SERVER_ENV="/root/xhttp-reality-server-secrets.env"
CAMO_ENV="$CONFIG_DIR/camouflage.env"
XRAY_SERVICE="xhttp-reality-server.service"
CAMOUFLAGE_HOST="${REALITY_CAMOUFLAGE_HOST:-noded.cloud}"
CAMOUFLAGE_PORT="${REALITY_CAMOUFLAGE_PORT:-443}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
for cmd in curl python3 systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd"; exit 1; }
done
[[ -x "$XRAY_DIR/xray" && -f "$SERVER_JSON" && -f "$CLIENT_ENV" && -f "$SERVER_ENV" ]] || {
  echo "Current Foreign XHTTP/REALITY installation not found."; exit 1;
}
[[ "$CAMOUFLAGE_PORT" =~ ^[0-9]+$ ]] && (( CAMOUFLAGE_PORT >= 1 && CAMOUFLAGE_PORT <= 65535 )) || {
  echo "Invalid REALITY_CAMOUFLAGE_PORT: $CAMOUFLAGE_PORT"; exit 1;
}

read_camo_env() {
  [[ -f "$CAMO_ENV" ]] || return 1
  read -r CAMOUFLAGE_HOST CAMOUFLAGE_PORT < <(python3 - "$CAMO_ENV" <<'PY'
import ast, sys
vals={}
for line in open(sys.argv[1]):
    if "=" not in line or line.lstrip().startswith("#"):
        continue
    k,v=line.strip().split("=",1)
    try: vals[k]=ast.literal_eval(v)
    except Exception: vals[k]=v.strip("'\"")
print(vals.get("CAMOUFLAGE_HOST", ""), vals.get("CAMOUFLAGE_PORT", "443"))
PY
)
  [[ -n "$CAMOUFLAGE_HOST" && "$CAMOUFLAGE_PORT" =~ ^[0-9]+$ ]]
}

validate_target() {
  local host="$1" port="$2"
  echo "Validating camouflage target ${host}:${port}..."
  python3 - "$host" <<'PY'
import socket, sys
name=sys.argv[1]
ips=sorted({x[4][0] for x in socket.getaddrinfo(name, 443, socket.AF_INET, socket.SOCK_STREAM)})
if not ips:
    raise SystemExit(f'No IPv4 records for {name}')
print('Resolved IPv4:', ', '.join(ips))
PY
  curl -4 -fsS --max-time 15 --connect-timeout 6 "https://${host}:${port}/" >/dev/null
  if "$XRAY_DIR/xray" tls ping "${host}:${port}" >/tmp/xhttp-reality-camouflage-tls-ping.log 2>&1; then
    echo "Xray TLS probe: OK"
  else
    echo "WARNING: xray tls ping was not fully successful; HTTPS validation passed."
    sed -n '1,20p' /tmp/xhttp-reality-camouflage-tls-ping.log || true
  fi
}

fallback_test() {
  local host="$1"
  curl -4 -fsS --max-time 15 --connect-timeout 6 \
    --resolve "${host}:443:127.0.0.1" \
    "https://${host}/" >/dev/null
}

if [[ "$MODE" == "status" ]]; then
  if read_camo_env; then
    echo "Camouflage SNI   : $CAMOUFLAGE_HOST"
    echo "Camouflage target: ${CAMOUFLAGE_HOST}:${CAMOUFLAGE_PORT}"
  else
    echo "Camouflage target has not been prepared yet."
  fi
  systemctl is-active "$XRAY_SERVICE" || true
  exit 0
fi

if [[ "$MODE" == "prepare" ]]; then
  validate_target "$CAMOUFLAGE_HOST" "$CAMOUFLAGE_PORT"
  mkdir -p "$CONFIG_DIR"
  cat >"$CAMO_ENV" <<EOF
CAMOUFLAGE_HOST='${CAMOUFLAGE_HOST}'
CAMOUFLAGE_PORT='${CAMOUFLAGE_PORT}'
EOF
  chmod 600 "$CAMO_ENV"
  echo
  echo "============================================================"
  echo "FOREIGN CAMOUFLAGE PREPARED - NO REALITY CHANGE YET"
  echo "NEW_SNI=$CAMOUFLAGE_HOST"
  echo "NEW_TARGET=${CAMOUFLAGE_HOST}:${CAMOUFLAGE_PORT}"
  echo "Next: stage NEW_SNI on Iran, then run this script with: activate"
  echo "============================================================"
  exit 0
fi

read_camo_env || { echo "Run '$0 prepare' first."; exit 1; }
validate_target "$CAMOUFLAGE_HOST" "$CAMOUFLAGE_PORT"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/lib/xhttp-reality-backups/$STAMP-hardening"
mkdir -p "$BACKUP_DIR"
chmod 700 /var/lib/xhttp-reality-backups "$BACKUP_DIR"
cp -a "$SERVER_JSON" "$BACKUP_DIR/server.json"
cp -a "$CLIENT_ENV" "$BACKUP_DIR/xhttp-reality-client.env"
cp -a "$SERVER_ENV" "$BACKUP_DIR/xhttp-reality-server-secrets.env"
[[ -d /etc/systemd/system/${XRAY_SERVICE}.d ]] && cp -a /etc/systemd/system/${XRAY_SERVICE}.d "$BACKUP_DIR/xray-dropins" || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SERVER_JSON" "$TMP/server.json" "$CAMOUFLAGE_HOST" "$CAMOUFLAGE_PORT" <<'PY'
import json, sys
src,dst,sni,port=sys.argv[1:]
obj=json.load(open(src))
ins=obj.get("inbounds") or []
if len(ins)!=1:
    raise SystemExit("Unexpected server config: expected one inbound")
rs=ins[0].setdefault("streamSettings",{}).setdefault("realitySettings",{})
rs["target"]=f"{sni}:{int(port)}"
rs["serverNames"]=[sni]
with open(dst,"w") as f:
    json.dump(obj,f,indent=2)
    f.write("\n")
PY
"$XRAY_DIR/xray" run -test -c "$TMP/server.json" >/dev/null

python3 - "$CLIENT_ENV" "$TMP/client.env" "$CAMOUFLAGE_HOST" <<'PY'
import sys
src,dst,sni=sys.argv[1:]
lines=open(src).read().splitlines()
out=[]; seen=False
for line in lines:
    if line.startswith("SNI="):
        out.append("SNI="+repr(sni)); seen=True
    else:
        out.append(line)
if not seen:
    out.append("SNI="+repr(sni))
open(dst,"w").write("\n".join(out)+"\n")
PY

python3 - "$SERVER_ENV" "$TMP/server.env" "$CAMOUFLAGE_HOST" "$CAMOUFLAGE_PORT" <<'PY'
import sys
src,dst,host,port=sys.argv[1:]
target=f"{host}:{int(port)}"
lines=open(src).read().splitlines()
out=[]; seen=False
for line in lines:
    if line.startswith("TARGET="):
        out.append("TARGET="+repr(target)); seen=True
    else:
        out.append(line)
if not seen:
    out.append("TARGET="+repr(target))
open(dst,"w").write("\n".join(out)+"\n")
PY

rollback() {
  echo "Activation failed; rolling back Foreign REALITY..."
  cp -a "$BACKUP_DIR/server.json" "$SERVER_JSON" || true
  cp -a "$BACKUP_DIR/xhttp-reality-client.env" "$CLIENT_ENV" || true
  cp -a "$BACKUP_DIR/xhttp-reality-server-secrets.env" "$SERVER_ENV" || true
  rm -rf /etc/systemd/system/${XRAY_SERVICE}.d
  if [[ -d "$BACKUP_DIR/xray-dropins" ]]; then
    cp -a "$BACKUP_DIR/xray-dropins" /etc/systemd/system/${XRAY_SERVICE}.d
  fi
  systemctl daemon-reload || true
  systemctl restart "$XRAY_SERVICE" || true
  echo "Rollback backup: $BACKUP_DIR"
}
trap rollback ERR

install -m 0600 "$TMP/server.json" "$SERVER_JSON"
install -m 0600 "$TMP/client.env" "$CLIENT_ENV"
install -m 0600 "$TMP/server.env" "$SERVER_ENV"

mkdir -p /etc/systemd/system/${XRAY_SERVICE}.d
cat >/etc/systemd/system/${XRAY_SERVICE}.d/10-hardening.conf <<'EOF'
[Service]
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
EOF

echo
echo "Activating REALITY camouflage. Immediately activate the staged SNI on Iran after this succeeds."
systemctl daemon-reload
systemctl restart "$XRAY_SERVICE"
sleep 2
systemctl is-active --quiet "$XRAY_SERVICE"
fallback_test "$CAMOUFLAGE_HOST"

trap - ERR
echo
echo "============================================================"
echo "FOREIGN REALITY HARDENING ACTIVE"
echo "NEW_SNI=$CAMOUFLAGE_HOST"
echo "TARGET=${CAMOUFLAGE_HOST}:${CAMOUFLAGE_PORT}"
echo "Credentials unchanged except SNI/target."
echo "Backup=$BACKUP_DIR"
echo "NOW ACTIVATE THE STAGED SNI ON IRAN."
echo "============================================================"

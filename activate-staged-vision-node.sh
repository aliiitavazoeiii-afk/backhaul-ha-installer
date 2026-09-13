#!/usr/bin/env bash
set -Eeuo pipefail

NODE="${1:-}"
case "$NODE" in f1|f2) ;; *) echo "Usage: $0 f1|f2"; exit 2 ;; esac

CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
CONTROLLER="xhttp-dual-controller.service"
NUM="${NODE#f}"
VISION_ENV="$CONFIG_DIR/foreign${NUM}-vision.env"
VISION_SERVICE="xhttp-dual-${NODE}-vision.service"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f "$CONFIG_DIR/config.json" && -f "$STATE_DIR/state.json" && -f "$VISION_ENV" ]] || { echo "Required dual/Vision files missing for $NODE"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }
command -v curl >/dev/null || { echo "curl missing"; exit 1; }
systemctl is-active --quiet "$VISION_SERVICE" || { echo "$VISION_SERVICE is not active"; exit 1; }

read -r NEW_SOCKS NEW_IP NEW_PORT < <(python3 - "$VISION_ENV" <<'PY'
import ast,sys
vals={}
for line in open(sys.argv[1]):
    if '=' not in line or line.lstrip().startswith('#'): continue
    k,v=line.strip().split('=',1)
    try: vals[k]=ast.literal_eval(v)
    except Exception: vals[k]=v.strip("'\"")
print(vals.get('SOCKS_PORT',''), vals.get('FOREIGN_IP',''), vals.get('PORT','443'))
PY
)
[[ "$NEW_SOCKS" =~ ^[0-9]+$ ]] || { echo "Invalid staged SOCKS port"; exit 1; }
[[ -n "$NEW_IP" && "$NEW_PORT" =~ ^[0-9]+$ ]] || { echo "Invalid staged Foreign metadata"; exit 1; }

ASSIGNED="$(python3 - "$STATE_DIR/state.json" "$NODE" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); node=sys.argv[2]
print(sum(1 for u in s.get('users',{}).values() if u.get('effective')==node))
PY
)"
if [[ "$ASSIGNED" != "0" ]]; then
  echo "REFUSING: ${NODE^^} still has ${ASSIGNED} effective users."
  echo "Fail/drain them to the survivor first, then rerun this helper."
  exit 1
fi

echo "[1/5] Verifying staged Vision backend 127.0.0.1:${NEW_SOCKS}..."
OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${NEW_SOCKS}" https://cp.cloudflare.com/generate_204 2>/dev/null || true)"
CODE="${OUT%% *}"
[[ "$CODE" == "200" || "$CODE" == "204" ]] || { echo "Vision candidate failed: $OUT"; exit 1; }
EGRESS="$(curl -fsS --max-time 15 --connect-timeout 5 --socks5-hostname "127.0.0.1:${NEW_SOCKS}" https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
echo "Vision candidate OK: $OUT egress=${EGRESS:-unknown}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$STATE_DIR/vision-migration-backups/${STAMP}-${NODE}-direct-activate"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
cp -a "$CONFIG_DIR/config.json" "$BACKUP/config.json"
cp -a "$STATE_DIR/state.json" "$BACKUP/state.json"

CONTROLLER_WAS_ACTIVE=0
systemctl is-active --quiet "$CONTROLLER" && CONTROLLER_WAS_ACTIVE=1 || true

echo "[2/5] Pausing controller and keeping ${NODE^^} drained..."
(( CONTROLLER_WAS_ACTIVE == 1 )) && systemctl stop "$CONTROLLER"

python3 - "$STATE_DIR/state.json" "$NODE" "$OUT" <<'PY'
import datetime,json,os,sys,tempfile
p,node,detail=sys.argv[1:]
o=json.load(open(p)); ns=o.setdefault('nodes',{}).setdefault(node,{})
ns['healthy']=True
ns['drained']=True
ns['failures']=0
ns['slow_failures']=0
ns['successes']=1
ns['last_reason']='ok'
ns['last_detail']='staged vision direct activation verified: '+detail
ns['last_change']=datetime.datetime.now().isoformat(timespec='seconds')
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=os.path.dirname(p)); os.close(fd)
with open(tmp,'w') as f: json.dump(o,f,indent=2,sort_keys=True); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY

echo "[3/5] Pointing controller/x-ui metadata directly to staged Vision SOCKS ${NEW_SOCKS}..."
python3 - "$CONFIG_DIR/config.json" "$NODE" "$NEW_IP" "$NEW_PORT" "$NEW_SOCKS" <<'PY'
import json,os,sys,tempfile
p,node,ip,port,socks=sys.argv[1:]
o=json.load(open(p)); nc=o['nodes'][node]
nc['foreign_ip']=ip
nc['foreign_port']=int(port)
nc['socks_port']=int(socks)
nc['transport']='vision-raw'
nc['vision_backend_socks_port']=int(socks)
fd,tmp=tempfile.mkstemp(prefix='.config.',dir=os.path.dirname(p)); os.close(fd)
with open(tmp,'w') as f: json.dump(o,f,indent=2,sort_keys=True); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY

(( CONTROLLER_WAS_ACTIVE == 1 )) && systemctl start "$CONTROLLER"
sleep 2

rollback() {
  echo "Activation verification failed; restoring metadata/state."
  systemctl stop "$CONTROLLER" 2>/dev/null || true
  cp -a "$BACKUP/config.json" "$CONFIG_DIR/config.json"
  cp -a "$BACKUP/state.json" "$STATE_DIR/state.json"
  (( CONTROLLER_WAS_ACTIVE == 1 )) && systemctl start "$CONTROLLER" 2>/dev/null || true
  exit 1
}

trap rollback ERR

echo "[4/5] Verifying controller now sees ${NODE^^} through 127.0.0.1:${NEW_SOCKS}..."
curl -fsS --max-time 15 --connect-timeout 5 --socks5-hostname "127.0.0.1:${NEW_SOCKS}" https://api.ipify.org >/dev/null

if command -v xhttp-dual >/dev/null 2>&1; then
  xhttp-dual status || true
fi

trap - ERR
echo "[5/5] ${NODE^^} staged Vision is ACTIVE in metadata and remains DRAINED."
echo "No x-ui routing apply was requested because ${NODE^^} had 0 assigned users."
echo "When ready to restore home users: xhttp-dual undrain ${NODE}"
echo "Backup: $BACKUP"

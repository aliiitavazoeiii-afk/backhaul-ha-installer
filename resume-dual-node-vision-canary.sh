#!/usr/bin/env bash
set -Eeuo pipefail

NODE="${1:-}"
case "$NODE" in f1|f2) ;; *) echo "Usage: $0 f1|f2"; exit 2 ;; esac

INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
CONTROLLER="xhttp-dual-controller.service"
NUM="${NODE#f}"
VISION_ENV="$CONFIG_DIR/foreign${NUM}-vision.env"
VISION_SERVICE="xhttp-dual-${NODE}-vision.service"
REDIRECT_HELPER="$INSTALL_DIR/vision-redirect-${NODE}.sh"
REDIRECT_SERVICE="xhttp-dual-${NODE}-vision-redirect.service"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f "$CONFIG_DIR/config.json" && -f "$VISION_ENV" ]] || { echo "Staged Vision config/env not found for $NODE"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }
command -v curl >/dev/null || { echo "curl missing"; exit 1; }
IPTABLES="$(command -v iptables || true)"
[[ -n "$IPTABLES" ]] || { echo "iptables is required"; exit 1; }

read -r OLD_SOCKS NEW_SOCKS NEW_IP NEW_PORT XUI_SERVICE < <(python3 - "$CONFIG_DIR/config.json" "$VISION_ENV" "$NODE" <<'PY'
import ast,json,sys
cfgp,envp,node=sys.argv[1:]
cfg=json.load(open(cfgp))
vals={}
for line in open(envp):
    if '=' not in line or line.lstrip().startswith('#'): continue
    k,v=line.strip().split('=',1)
    try: vals[k]=ast.literal_eval(v)
    except Exception: vals[k]=v.strip("'\"")
print(cfg['nodes'][node]['socks_port'], vals.get('SOCKS_PORT',''), vals.get('FOREIGN_IP',''), vals.get('PORT','443'), cfg.get('xui_service','x-ui'))
PY
)
[[ "$OLD_SOCKS" =~ ^[0-9]+$ && "$NEW_SOCKS" =~ ^[0-9]+$ ]] || { echo "Invalid SOCKS ports"; exit 1; }
[[ -n "$NEW_IP" && "$NEW_PORT" =~ ^[0-9]+$ ]] || { echo "Invalid staged Foreign metadata"; exit 1; }

systemctl is-active --quiet "$VISION_SERVICE" || { echo "$VISION_SERVICE is not active"; exit 1; }
ss -lntH "( sport = :${NEW_SOCKS} )" | grep -q . || { echo "Vision TCP SOCKS $NEW_SOCKS is not listening"; exit 1; }
ss -lunH "( sport = :${NEW_SOCKS} )" | grep -q . || { echo "Vision UDP SOCKS $NEW_SOCKS is not listening"; exit 1; }

echo "[1/6] Verifying staged Vision backend directly on 127.0.0.1:${NEW_SOCKS}..."
DETAIL=""
OK=0
for URL in "https://cp.cloudflare.com/generate_204" "https://connectivitycheck.gstatic.com/generate_204" "https://captive.apple.com/hotspot-detect.html"; do
  OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${NEW_SOCKS}" "$URL" 2>/dev/null || true)"
  CODE="${OUT%% *}"; TOTAL="${OUT#* }"; DETAIL="${URL} code=${CODE:-'-'} total=${TOTAL:-'-'}"
  if [[ "$CODE" == "200" || "$CODE" == "204" ]]; then OK=1; echo "Vision candidate OK: $DETAIL"; break; fi
  echo "Vision candidate target failed: $DETAIL"
done
(( OK == 1 )) || { echo "Staged Vision path is not healthy. Nothing changed."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$STATE_DIR/vision-migration-backups/${STAMP}-${NODE}-canary"
mkdir -p "$BACKUP"
chmod 700 "$STATE_DIR" "$STATE_DIR/vision-migration-backups" "$BACKUP" 2>/dev/null || true
cp -a "$CONFIG_DIR/config.json" "$BACKUP/config.json"
[[ -f "$STATE_DIR/state.json" ]] && cp -a "$STATE_DIR/state.json" "$BACKUP/state.json"
[[ -f "/etc/systemd/system/$REDIRECT_SERVICE" ]] && cp -a "/etc/systemd/system/$REDIRECT_SERVICE" "$BACKUP/redirect.service.old"
[[ -f "$REDIRECT_HELPER" ]] && cp -a "$REDIRECT_HELPER" "$BACKUP/redirect-helper.old"

CONTROLLER_WAS_ACTIVE=0
systemctl is-active --quiet "$CONTROLLER" 2>/dev/null && CONTROLLER_WAS_ACTIVE=1 || true
XUI_PID_BEFORE="$(systemctl show -p MainPID --value "$XUI_SERVICE" 2>/dev/null || true)"

rollback() {
  echo
  echo "Canary cutover failed; removing redirect and restoring controller state..."
  systemctl disable --now "$REDIRECT_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$REDIRECT_SERVICE" "$REDIRECT_HELPER"
  systemctl daemon-reload || true
  cp -a "$BACKUP/config.json" "$CONFIG_DIR/config.json" || true
  [[ -f "$BACKUP/state.json" ]] && cp -a "$BACKUP/state.json" "$STATE_DIR/state.json" || true
  (( CONTROLLER_WAS_ACTIVE == 1 )) && systemctl start "$CONTROLLER" 2>/dev/null || true
  echo "Old ${NODE^^} service was never stopped. Backup: $BACKUP"
}
trap rollback ERR

echo "[2/6] Pausing health controller and marking ${NODE^^} DRAINED before redirect..."
(( CONTROLLER_WAS_ACTIVE == 1 )) && systemctl stop "$CONTROLLER"
python3 - "$STATE_DIR/state.json" "$NODE" "$DETAIL" <<'PY'
import datetime,json,os,sys,tempfile
p,node,detail=sys.argv[1:]
if os.path.exists(p): obj=json.load(open(p))
else:
    obj={'version':1,'rr_next':'f1','users':{},'nodes':{'f1':{},'f2':{}},'last_apply':None,'last_error':None}
ns=obj.setdefault('nodes',{}).setdefault(node,{})
ns['healthy']=True
ns['drained']=True
ns['failures']=0
ns['slow_failures']=0
ns['successes']=1
ns['last_reason']='ok'
ns['last_detail']='vision canary verified: '+detail
ns['last_change']=datetime.datetime.now().isoformat(timespec='seconds')
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=os.path.dirname(p)); os.close(fd)
with open(tmp,'w') as f: json.dump(obj,f,indent=2,sort_keys=True); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY

echo "[3/6] Installing persistent TCP+UDP redirect ${OLD_SOCKS} -> ${NEW_SOCKS}..."
cat >"$REDIRECT_HELPER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IPT='${IPTABLES}'
OLD='${OLD_SOCKS}'
NEW='${NEW_SOCKS}'
add_rule() {
  local proto="\$1"
  "\$IPT" -w 5 -t nat -C OUTPUT -p "\$proto" -d 127.0.0.1 --dport "\$OLD" -j REDIRECT --to-ports "\$NEW" 2>/dev/null || \
    "\$IPT" -w 5 -t nat -I OUTPUT 1 -p "\$proto" -d 127.0.0.1 --dport "\$OLD" -j REDIRECT --to-ports "\$NEW"
}
del_rule() {
  local proto="\$1"
  while "\$IPT" -w 5 -t nat -C OUTPUT -p "\$proto" -d 127.0.0.1 --dport "\$OLD" -j REDIRECT --to-ports "\$NEW" 2>/dev/null; do
    "\$IPT" -w 5 -t nat -D OUTPUT -p "\$proto" -d 127.0.0.1 --dport "\$OLD" -j REDIRECT --to-ports "\$NEW"
  done
}
case "\${1:-}" in
  start) add_rule tcp; add_rule udp ;;
  stop) del_rule tcp; del_rule udp ;;
  *) echo "usage: \$0 start|stop"; exit 2 ;;
esac
EOF
chmod 0755 "$REDIRECT_HELPER"
cat >"/etc/systemd/system/$REDIRECT_SERVICE" <<EOF
[Unit]
Description=Redirect ${NODE^^} compatibility SOCKS to Vision backend
After=network-online.target ${VISION_SERVICE}
Requires=${VISION_SERVICE}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${REDIRECT_HELPER} start
ExecStop=${REDIRECT_HELPER} stop

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$REDIRECT_SERVICE"
"$IPTABLES" -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport "$OLD_SOCKS" -j REDIRECT --to-ports "$NEW_SOCKS"
"$IPTABLES" -t nat -C OUTPUT -p udp -d 127.0.0.1 --dport "$OLD_SOCKS" -j REDIRECT --to-ports "$NEW_SOCKS"

echo "[4/6] Verifying ORIGINAL SOCKS port now reaches Vision..."
OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${OLD_SOCKS}" https://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)"
CODE="${OUT%% *}"
[[ "$CODE" == "200" || "$CODE" == "204" ]] || { echo "Compatibility SOCKS verification failed: $OUT"; false; }
echo "Compatibility SOCKS OK: $OUT"

echo "[5/6] Updating node metadata, while keeping ${NODE^^} drained from user routing..."
python3 - "$CONFIG_DIR/config.json" "$NODE" "$NEW_IP" "$NEW_PORT" "$NEW_SOCKS" <<'PY'
import json,os,sys,tempfile
p,node,ip,port,stage=sys.argv[1:]
obj=json.load(open(p)); nc=obj['nodes'][node]
nc['foreign_ip']=ip
nc['foreign_port']=int(port)
nc['transport']='vision-raw'
nc['vision_backend_socks_port']=int(stage)
fd,tmp=tempfile.mkstemp(prefix='.config.',dir=os.path.dirname(p)); os.close(fd)
with open(tmp,'w') as f: json.dump(obj,f,indent=2,sort_keys=True); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY

(( CONTROLLER_WAS_ACTIVE == 1 )) && systemctl start "$CONTROLLER"
sleep 2
(( CONTROLLER_WAS_ACTIVE == 0 )) || systemctl is-active --quiet "$CONTROLLER"

XUI_PID_AFTER="$(systemctl show -p MainPID --value "$XUI_SERVICE" 2>/dev/null || true)"
if [[ -n "$XUI_PID_BEFORE" && "$XUI_PID_BEFORE" != "0" && "$XUI_PID_BEFORE" != "$XUI_PID_AFTER" ]]; then
  echo "WARNING: x-ui PID changed unexpectedly: $XUI_PID_BEFORE -> $XUI_PID_AFTER"
else
  echo "x-ui PID unchanged: ${XUI_PID_AFTER:-unknown}"
fi

echo "[6/6] Canary status..."
command -v xhttp-dual >/dev/null 2>&1 && xhttp-dual status || true

trap - ERR
echo
echo "============================================================"
echo "${NODE^^} VISION CANARY READY - DRAINED"
echo "Compatibility SOCKS : 127.0.0.1:${OLD_SOCKS} -> Vision ${NEW_SOCKS}"
echo "Vision Foreign      : ${NEW_IP}:${NEW_PORT}"
echo "TCP+UDP redirect    : ACTIVE"
echo "User assignments    : unchanged; ${NODE^^} remains drained"
echo "x-ui restart        : NO (PID check above)"
echo "Old ${NODE^^} service    : still running, but new localhost connections are redirected"
echo "Backup              : $BACKUP"
echo "============================================================"

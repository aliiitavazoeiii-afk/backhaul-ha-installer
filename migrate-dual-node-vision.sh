#!/usr/bin/env bash
set -Eeuo pipefail

NODE="${1:-}"
case "$NODE" in f1|f2) ;; *) echo "Usage: $0 f1|f2"; exit 2 ;; esac

INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
CONTROLLER="xhttp-dual-controller.service"
XRAY="$INSTALL_DIR/xray"
NUM="${NODE#f}"
OLD_SOCKS="$(python3 - "$CONFIG_DIR/config.json" "$NODE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['nodes'][sys.argv[2]]['socks_port'])
PY
)"
if [[ "$NODE" == "f1" ]]; then NEW_SOCKS="${VISION_STAGE_PORT:-12818}"; else NEW_SOCKS="${VISION_STAGE_PORT:-12819}"; fi
VISION_JSON="$CONFIG_DIR/${NODE}-vision.json"
VISION_ENV="$CONFIG_DIR/foreign${NUM}-vision.env"
VISION_SERVICE="xhttp-dual-${NODE}-vision.service"
REDIRECT_HELPER="$INSTALL_DIR/vision-redirect-${NODE}.sh"
REDIRECT_SERVICE="xhttp-dual-${NODE}-vision-redirect.service"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -x "$XRAY" && -f "$CONFIG_DIR/config.json" ]] || { echo "Current dual Iran install not found."; exit 1; }
command -v curl >/dev/null || { echo "curl missing"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }
IPTABLES="$(command -v iptables || true)"
[[ -n "$IPTABLES" ]] || { echo "iptables command is required for zero-restart cutover."; exit 1; }
[[ "$OLD_SOCKS" =~ ^[0-9]+$ && "$NEW_SOCKS" =~ ^[0-9]+$ ]] || { echo "Invalid SOCKS port"; exit 1; }
[[ "$OLD_SOCKS" != "$NEW_SOCKS" ]] || { echo "Stage port must differ from live SOCKS port"; exit 1; }
if ss -lntH "( sport = :${NEW_SOCKS} )" 2>/dev/null | grep -q .; then
  echo "Stage port ${NEW_SOCKS} is already in use:"; ss -lntp "( sport = :${NEW_SOCKS} )" || true; exit 1
fi

prompt() { local var="$1" text="$2" def="${3:-}" val=""; read -r -p "$text${def:+ [$def]}: " val; printf -v "$var" '%s' "${val:-$def}"; }

echo "============================================================"
echo "DUAL IRAN - STAGE ${NODE^^} AS VLESS + REALITY + VISION RAW"
echo "The current ${NODE^^} listener on 127.0.0.1:${OLD_SOCKS} is NOT restarted."
echo "A candidate starts on 127.0.0.1:${NEW_SOCKS}; it is tested first."
echo "Cutover uses a local NAT redirect for NEW SOCKS connections only."
echo "Existing established ${NODE^^} TCP/SOCKS sessions are not deliberately closed."
echo "============================================================"

prompt NEW_IP "New Foreign ${NODE^^} IP/domain"
prompt NEW_PORT "New Foreign ${NODE^^} port" "443"
prompt NEW_UUID "VLESS ID"
prompt NEW_PASSWORD "REALITY Password/PublicKey"
prompt NEW_SID "REALITY Short ID"
prompt NEW_SNI "REALITY SNI (exact value from vision-reality-client.env)" "dl.google.com"

[[ -n "$NEW_IP" && -n "$NEW_UUID" && -n "$NEW_PASSWORD" && -n "$NEW_SID" && -n "$NEW_SNI" ]] || { echo "All values are required."; exit 1; }
[[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 1 && NEW_PORT <= 65535 )) || { echo "Invalid port"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$STATE_DIR/vision-migration-backups/${STAMP}-${NODE}"
mkdir -p "$BACKUP"
chmod 700 "$STATE_DIR" "$STATE_DIR/vision-migration-backups" "$BACKUP" 2>/dev/null || true
cp -a "$CONFIG_DIR/config.json" "$BACKUP/config.json"
[[ -f "$STATE_DIR/state.json" ]] && cp -a "$STATE_DIR/state.json" "$BACKUP/state.json"
[[ -f "$VISION_JSON" ]] && cp -a "$VISION_JSON" "$BACKUP/vision.json.old"
[[ -f "$VISION_ENV" ]] && cp -a "$VISION_ENV" "$BACKUP/vision.env.old"
[[ -f "/etc/systemd/system/$VISION_SERVICE" ]] && cp -a "/etc/systemd/system/$VISION_SERVICE" "$BACKUP/vision.service.old"
[[ -f "/etc/systemd/system/$REDIRECT_SERVICE" ]] && cp -a "/etc/systemd/system/$REDIRECT_SERVICE" "$BACKUP/redirect.service.old"
[[ -f "$REDIRECT_HELPER" ]] && cp -a "$REDIRECT_HELPER" "$BACKUP/redirect-helper.old"

echo "[1/7] Building candidate Vision client on local SOCKS ${NEW_SOCKS}..."
cat >"$TMP/vision.json" <<EOF_JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "local-socks-${NODE}-vision",
    "listen": "127.0.0.1",
    "port": ${NEW_SOCKS},
    "protocol": "socks",
    "settings": {"auth": "noauth", "udp": true}
  }],
  "outbounds": [{
    "tag": "vision-${NODE}",
    "protocol": "vless",
    "settings": {"vnext": [{"address": "${NEW_IP}", "port": ${NEW_PORT}, "users": [{"id": "${NEW_UUID}", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {"show": false, "fingerprint": "chrome", "serverName": "${NEW_SNI}", "password": "${NEW_PASSWORD}", "shortId": "${NEW_SID}", "spiderX": "/"}
    }
  }]
}
EOF_JSON
python3 -m json.tool "$TMP/vision.json" >/dev/null
"$XRAY" run -test -c "$TMP/vision.json" >/dev/null
install -m 0600 "$TMP/vision.json" "$VISION_JSON"
cat >"$VISION_ENV" <<EOF_ENV
FOREIGN_IP='${NEW_IP}'
PORT='${NEW_PORT}'
VLESS_ID='${NEW_UUID}'
REALITY_PASSWORD='${NEW_PASSWORD}'
REALITY_SHORT_ID='${NEW_SID}'
SNI='${NEW_SNI}'
FLOW='xtls-rprx-vision'
TRANSPORT='raw'
SOCKS_PORT='${NEW_SOCKS}'
LIVE_COMPAT_SOCKS_PORT='${OLD_SOCKS}'
EOF_ENV
chmod 600 "$VISION_ENV"

cat >"/etc/systemd/system/$VISION_SERVICE" <<EOF_UNIT
[Unit]
Description=Dual ${NODE^^} staged VLESS REALITY Vision client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY} run -c ${VISION_JSON}
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF_UNIT
systemctl daemon-reload
systemctl enable --now "$VISION_SERVICE"
sleep 2
systemctl is-active --quiet "$VISION_SERVICE"
ss -lntH "( sport = :${NEW_SOCKS} )" | grep -q .

echo "[2/7] Testing candidate end-to-end before touching live traffic..."
TEST_OK=0
HEALTH_DETAIL=""
for URL in "https://cp.cloudflare.com/generate_204" "https://connectivitycheck.gstatic.com/generate_204" "https://captive.apple.com/hotspot-detect.html"; do
  OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 25 --connect-timeout 8 --socks5-hostname "127.0.0.1:${NEW_SOCKS}" "$URL" 2>/dev/null || true)"
  CODE="${OUT%% *}"; TOTAL="${OUT#* }"; HEALTH_DETAIL="${URL} code=${CODE:-'-'} total=${TOTAL:-'-'}"
  case "$CODE" in 200|204) TEST_OK=1; echo "Candidate OK: $HEALTH_DETAIL"; break ;; *) echo "Candidate target failed: $HEALTH_DETAIL" ;; esac
done
(( TEST_OK == 1 )) || { echo "Candidate Vision tunnel failed. LIVE ${NODE^^} IS UNCHANGED."; exit 1; }

EGRESS="$(curl -fsS --max-time 15 --connect-timeout 5 --socks5-hostname "127.0.0.1:${NEW_SOCKS}" https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
echo "Candidate egress: ${EGRESS:-unknown}"

echo
read -r -p "Candidate passed. Redirect NEW ${NODE^^} SOCKS connections to Vision without restarting x-ui/old ${NODE^^}? Type YES: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Candidate left staged on ${NEW_SOCKS}; live traffic unchanged."; exit 0; }

rollback() {
  echo
  echo "Cutover failed; restoring previous control state and removing redirect..."
  systemctl disable --now "$REDIRECT_SERVICE" 2>/dev/null || true
  cp -a "$BACKUP/config.json" "$CONFIG_DIR/config.json" || true
  [[ -f "$BACKUP/state.json" ]] && cp -a "$BACKUP/state.json" "$STATE_DIR/state.json" || true
  systemctl restart "$CONTROLLER" 2>/dev/null || true
  echo "Old ${NODE^^} service was never stopped. Backup: $BACKUP"
}
trap rollback ERR

echo "[3/7] Installing persistent NEW-connection redirect ${OLD_SOCKS} -> ${NEW_SOCKS}..."
cat >"$REDIRECT_HELPER" <<EOF_HELPER
#!/usr/bin/env bash
set -Eeuo pipefail
IPT='${IPTABLES}'
OLD='${OLD_SOCKS}'
NEW='${NEW_SOCKS}'
case "\${1:-}" in
  start)
    "\$IPT" -w 5 -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport "\$OLD" -j REDIRECT --to-ports "\$NEW" 2>/dev/null || \
      "\$IPT" -w 5 -t nat -I OUTPUT 1 -p tcp -d 127.0.0.1 --dport "\$OLD" -j REDIRECT --to-ports "\$NEW"
    ;;
  stop)
    while "\$IPT" -w 5 -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport "\$OLD" -j REDIRECT --to-ports "\$NEW" 2>/dev/null; do
      "\$IPT" -w 5 -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport "\$OLD" -j REDIRECT --to-ports "\$NEW"
    done
    ;;
  *) echo "usage: \$0 start|stop"; exit 2 ;;
esac
EOF_HELPER
chmod 0755 "$REDIRECT_HELPER"
cat >"/etc/systemd/system/$REDIRECT_SERVICE" <<EOF_UNIT
[Unit]
Description=Redirect new ${NODE^^} local SOCKS connections to staged Vision backend
After=network-online.target ${VISION_SERVICE}
Requires=${VISION_SERVICE}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${REDIRECT_HELPER} start
ExecStop=${REDIRECT_HELPER} stop

[Install]
WantedBy=multi-user.target
EOF_UNIT
systemctl daemon-reload
systemctl enable --now "$REDIRECT_SERVICE"

"$IPTABLES" -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport "$OLD_SOCKS" -j REDIRECT --to-ports "$NEW_SOCKS"

echo "[4/7] Verifying traffic through the ORIGINAL SOCKS port now reaches Vision..."
OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 25 --connect-timeout 8 --socks5-hostname "127.0.0.1:${OLD_SOCKS}" https://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)"
CODE="${OUT%% *}"
[[ "$CODE" == "204" || "$CODE" == "200" ]] || { echo "Live compatibility-port verification failed: $OUT"; false; }
echo "Compatibility SOCKS test OK: $OUT"

echo "[5/7] Updating controller metadata only; sticky mappings and x-ui template stay unchanged..."
python3 - "$CONFIG_DIR/config.json" "$NODE" "$NEW_IP" "$NEW_PORT" "$NEW_SOCKS" <<'PY'
import json, os, sys, tempfile
p,node,ip,port,stage_port=sys.argv[1:]
obj=json.load(open(p)); nc=obj['nodes'][node]
nc['foreign_ip']=ip; nc['foreign_port']=int(port); nc['transport']='vision-raw'; nc['vision_backend_socks_port']=int(stage_port)
fd,tmp=tempfile.mkstemp(prefix='.config.',dir=os.path.dirname(p)); os.close(fd)
with open(tmp,'w') as f: json.dump(obj,f,indent=2,sort_keys=True); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY
if [[ -f "$STATE_DIR/state.json" ]]; then
  python3 - "$STATE_DIR/state.json" "$NODE" "$HEALTH_DETAIL" <<'PY'
import json, os, sys, tempfile, datetime
p,node,detail=sys.argv[1:]; obj=json.load(open(p)); ns=obj['nodes'][node]
ns['healthy']=True; ns['failures']=0; ns['slow_failures']=0; ns['successes']=1; ns['drained']=False
ns['last_reason']='ok'; ns['last_detail']='vision migration verified: '+detail
ns['last_change']=datetime.datetime.now().isoformat(timespec='seconds')
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=os.path.dirname(p)); os.close(fd)
with open(tmp,'w') as f: json.dump(obj,f,indent=2,sort_keys=True); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY
fi

echo "[6/7] Restarting ONLY the health controller so it reloads metadata..."
systemctl restart "$CONTROLLER"
sleep 2
systemctl is-active --quiet "$CONTROLLER"

echo "[7/7] Status..."
command -v xhttp-dual >/dev/null 2>&1 && xhttp-dual status || true
command -v xhttp-dual >/dev/null 2>&1 && xhttp-dual netcheck || true

trap - ERR
echo
echo "============================================================"
echo "${NODE^^} VISION CANARY CUTOVER ACTIVE"
echo "Old live SOCKS : 127.0.0.1:${OLD_SOCKS} (old service still running)"
echo "Vision backend : 127.0.0.1:${NEW_SOCKS} -> ${NEW_IP}:${NEW_PORT}"
echo "New connections: redirected to Vision"
echo "Existing old connections: not deliberately terminated"
echo "x-ui restart   : NO"
echo "old ${NODE^^} restart : NO"
echo "Backup         : ${BACKUP}"
echo "============================================================"

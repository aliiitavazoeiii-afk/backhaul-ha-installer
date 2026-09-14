#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
CONTROLLER="xhttp-dual-controller.service"
XRAY="$INSTALL_DIR/xray"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -x "$XRAY" && -f "$CONFIG_DIR/config.json" ]] || { echo "Current dual install not found."; exit 1; }
command -v curl >/dev/null || { echo "curl missing"; exit 1; }
command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }

NODE="${1:-}"
if [[ -z "$NODE" ]]; then
  echo "============================================================"
  echo "DUAL VISION - REPLACE FOREIGN NODE"
  echo "VLESS + REALITY + XTLS Vision + RAW (NO XHTTP PATH)"
  echo "============================================================"
  echo "1) Replace Foreign #1 (F1)"
  echo "2) Replace Foreign #2 (F2)"
  echo "0) Exit"
  read -r -p "Select: " CHOICE
  case "$CHOICE" in
    1) NODE=f1 ;;
    2) NODE=f2 ;;
    0) exit 0 ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
fi
case "$NODE" in f1|f2) ;; *) echo "Usage: $0 [f1|f2]"; exit 2 ;; esac
NUM="${NODE#f}"

LIVE_SOCKS="$(python3 - "$CONFIG_DIR/config.json" "$NODE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['nodes'][sys.argv[2]]['socks_port'])
PY
)"
OLD_IP="$(python3 - "$CONFIG_DIR/config.json" "$NODE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['nodes'][sys.argv[2]].get('foreign_ip','-'))
PY
)"
TRANSPORT="$(python3 - "$CONFIG_DIR/config.json" "$NODE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['nodes'][sys.argv[2]].get('transport',''))
PY
)"
[[ "$LIVE_SOCKS" =~ ^[0-9]+$ ]] || { echo "Invalid live SOCKS port"; exit 1; }
if [[ "$TRANSPORT" != "vision-raw" ]]; then
  echo "REFUSING: ${NODE^^} transport is '${TRANSPORT:-unknown}', not vision-raw."
  echo "Do not use this helper for an XHTTP node."
  exit 1
fi

SERVICE=""
NODE_JSON=""
if systemctl cat "xhttp-dual-${NODE}-vision.service" >/dev/null 2>&1 && [[ -f "$CONFIG_DIR/${NODE}-vision.json" ]]; then
  SERVICE="xhttp-dual-${NODE}-vision.service"
  NODE_JSON="$CONFIG_DIR/${NODE}-vision.json"
elif systemctl cat "xhttp-dual-${NODE}.service" >/dev/null 2>&1 && [[ -f "$CONFIG_DIR/${NODE}.json" ]]; then
  SERVICE="xhttp-dual-${NODE}.service"
  NODE_JSON="$CONFIG_DIR/${NODE}.json"
else
  echo "Could not locate the active Vision service/config for ${NODE^^}."
  exit 1
fi

if ! grep -q 'xtls-rprx-vision' "$NODE_JSON" || ! grep -Eq '"network"[[:space:]]*:[[:space:]]*"raw"' "$NODE_JSON"; then
  echo "REFUSING: $NODE_JSON is not a Vision RAW client config."
  exit 1
fi

ENV_FILE="$CONFIG_DIR/foreign${NUM}-vision.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$CONFIG_DIR/foreign${NUM}.env"
CANDIDATE_PORT="${VISION_REPLACE_TEST_PORT:-$((13817 + NUM))}"
if ss -lntH "( sport = :${CANDIDATE_PORT} )" 2>/dev/null | grep -q .; then
  echo "Candidate port ${CANDIDATE_PORT} is already in use."
  echo "Set VISION_REPLACE_TEST_PORT to a free localhost port and retry."
  exit 1
fi

prompt() { local var="$1" text="$2" def="${3:-}" val=""; read -r -p "$text${def:+ [$def]}: " val; printf -v "$var" '%s' "${val:-$def}"; }

echo
echo "Current ${NODE^^}: ${OLD_IP}  (Vision RAW SOCKS 127.0.0.1:${LIVE_SOCKS})"
echo "Service: ${SERVICE}"
echo
prompt NEW_IP "New Foreign #${NUM} IP/domain"
prompt NEW_PORT "New Foreign #${NUM} port" "443"
prompt NEW_UUID "New Foreign #${NUM} VLESS ID"
prompt NEW_PASSWORD "New Foreign #${NUM} REALITY Password/PublicKey"
prompt NEW_SID "New Foreign #${NUM} Short ID"
prompt NEW_SNI "New Foreign #${NUM} REALITY SNI" "dl.google.com"

[[ -n "$NEW_IP" && -n "$NEW_UUID" && -n "$NEW_PASSWORD" && -n "$NEW_SID" && -n "$NEW_SNI" ]] || { echo "All values are required."; exit 1; }
[[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 1 && NEW_PORT <= 65535 )) || { echo "Invalid port"; exit 1; }

TMP="$(mktemp -d)"
CANDIDATE_PID=""
cleanup() {
  if [[ -n "$CANDIDATE_PID" ]]; then kill "$CANDIDATE_PID" 2>/dev/null || true; wait "$CANDIDATE_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

write_cfg() {
  local port="$1" out="$2"
  cat >"$out" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "local-socks-${NODE}-vision",
    "listen": "127.0.0.1",
    "port": ${port},
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
EOF
  python3 -m json.tool "$out" >/dev/null
  "$XRAY" run -test -c "$out" >/dev/null
}

write_cfg "$CANDIDATE_PORT" "$TMP/candidate.json"

echo "[1/5] Testing NEW Foreign through temporary SOCKS 127.0.0.1:${CANDIDATE_PORT}..."
"$XRAY" run -c "$TMP/candidate.json" >"$TMP/candidate.log" 2>&1 &
CANDIDATE_PID=$!
sleep 2
kill -0 "$CANDIDATE_PID" 2>/dev/null || { cat "$TMP/candidate.log"; echo "Candidate Xray failed to start."; exit 1; }
ss -lntH "( sport = :${CANDIDATE_PORT} )" | grep -q . || { cat "$TMP/candidate.log"; echo "Candidate SOCKS did not listen."; exit 1; }

OK=0
DETAIL=""
for URL in "https://cp.cloudflare.com/generate_204" "https://connectivitycheck.gstatic.com/generate_204" "https://captive.apple.com/hotspot-detect.html"; do
  OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${CANDIDATE_PORT}" "$URL" 2>/dev/null || true)"
  CODE="${OUT%% *}"
  DETAIL="${URL} ${OUT}"
  if [[ "$CODE" == "200" || "$CODE" == "204" ]]; then OK=1; break; fi
done
(( OK == 1 )) || { echo "Candidate failed: $DETAIL"; exit 1; }
EGRESS="$(curl -fsS --max-time 15 --connect-timeout 5 --socks5-hostname "127.0.0.1:${CANDIDATE_PORT}" https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
echo "Candidate OK: $DETAIL"
echo "Candidate egress: ${EGRESS:-unknown}"

echo
read -r -p "Replace ${NODE^^} ${OLD_IP} -> ${NEW_IP} now? Type YES: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Cancelled; live ${NODE^^} unchanged."; exit 0; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$STATE_DIR/vision-replacement-backups/${STAMP}-${NODE}"
mkdir -p "$BACKUP"
chmod 700 "$STATE_DIR/vision-replacement-backups" "$BACKUP" 2>/dev/null || true
cp -a "$NODE_JSON" "$BACKUP/node.json"
cp -a "$CONFIG_DIR/config.json" "$BACKUP/config.json"
[[ -f "$STATE_DIR/state.json" ]] && cp -a "$STATE_DIR/state.json" "$BACKUP/state.json"
[[ -f "$ENV_FILE" ]] && cp -a "$ENV_FILE" "$BACKUP/env.old"

CONTROLLER_WAS_ACTIVE=0
systemctl is-active --quiet "$CONTROLLER" && CONTROLLER_WAS_ACTIVE=1 || true

rollback() {
  echo
  echo "Replacement failed; restoring previous ${NODE^^}..."
  systemctl stop "$CONTROLLER" 2>/dev/null || true
  cp -a "$BACKUP/node.json" "$NODE_JSON" || true
  cp -a "$BACKUP/config.json" "$CONFIG_DIR/config.json" || true
  [[ -f "$BACKUP/state.json" ]] && cp -a "$BACKUP/state.json" "$STATE_DIR/state.json" || true
  [[ -f "$BACKUP/env.old" ]] && cp -a "$BACKUP/env.old" "$ENV_FILE" || true
  systemctl restart "$SERVICE" || true
  (( CONTROLLER_WAS_ACTIVE == 1 )) && systemctl start "$CONTROLLER" 2>/dev/null || true
  echo "Rollback complete. Backup: $BACKUP"
}
trap rollback ERR

(( CONTROLLER_WAS_ACTIVE == 1 )) && systemctl stop "$CONTROLLER"

echo "[2/5] Installing new Vision RAW config on live SOCKS ${LIVE_SOCKS}..."
write_cfg "$LIVE_SOCKS" "$TMP/live.json"
install -m 0600 "$TMP/live.json" "$NODE_JSON"

cat >"$ENV_FILE" <<EOF
FOREIGN_IP='${NEW_IP}'
PORT='${NEW_PORT}'
VLESS_ID='${NEW_UUID}'
REALITY_PASSWORD='${NEW_PASSWORD}'
REALITY_SHORT_ID='${NEW_SID}'
SNI='${NEW_SNI}'
FLOW='xtls-rprx-vision'
TRANSPORT='raw'
SOCKS_PORT='${LIVE_SOCKS}'
EOF
chmod 600 "$ENV_FILE"

echo "[3/5] Restarting ONLY ${SERVICE}..."
systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE"
ss -lntH "( sport = :${LIVE_SOCKS} )" | grep -q .

OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${LIVE_SOCKS}" https://cp.cloudflare.com/generate_204 2>/dev/null || true)"
CODE="${OUT%% *}"
[[ "$CODE" == "200" || "$CODE" == "204" ]] || { echo "Live Vision verification failed: $OUT"; false; }

echo "[4/5] Updating controller metadata; x-ui routing is NOT changed..."
python3 - "$CONFIG_DIR/config.json" "$NODE" "$NEW_IP" "$NEW_PORT" "$LIVE_SOCKS" <<'PY'
import json,os,sys,tempfile
p,node,ip,port,socks=sys.argv[1:]
o=json.load(open(p)); n=o['nodes'][node]
n['foreign_ip']=ip; n['foreign_port']=int(port); n['socks_port']=int(socks); n['transport']='vision-raw'; n['vision_backend_socks_port']=int(socks)
fd,tmp=tempfile.mkstemp(prefix='.config.',dir=os.path.dirname(p)); os.close(fd)
with open(tmp,'w') as f: json.dump(o,f,indent=2,sort_keys=True); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY
if [[ -f "$STATE_DIR/state.json" ]]; then
  python3 - "$STATE_DIR/state.json" "$NODE" "$DETAIL" <<'PY'
import datetime,json,os,sys,tempfile
p,node,detail=sys.argv[1:]; o=json.load(open(p)); n=o['nodes'][node]
n['healthy']=True; n['failures']=0; n['slow_failures']=0; n['successes']=1; n['last_reason']='ok'; n['last_detail']='vision replacement verified: '+detail; n['last_change']=datetime.datetime.now().isoformat(timespec='seconds')
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=os.path.dirname(p)); os.close(fd)
with open(tmp,'w') as f: json.dump(o,f,indent=2,sort_keys=True); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY
fi

(( CONTROLLER_WAS_ACTIVE == 1 )) && systemctl start "$CONTROLLER"
sleep 2

trap - ERR

echo "[5/5] Done."
command -v xhttp-dual >/dev/null 2>&1 && xhttp-dual status || true
echo
printf 'New %s egress: ' "${NODE^^}"
curl -fsS --max-time 10 --socks5-hostname "127.0.0.1:${LIVE_SOCKS}" https://api.ipify.org || true
echo
echo "============================================================"
echo "${NODE^^} VISION FOREIGN REPLACED"
echo "Old Foreign : ${OLD_IP}"
echo "New Foreign : ${NEW_IP}:${NEW_PORT}"
echo "Transport   : VLESS + REALITY + xtls-rprx-vision + RAW"
echo "XHTTP Path  : NOT USED"
echo "x-ui restart: NO"
echo "Note        : connections using ${NODE^^} reconnect once because its local Vision service restarted"
echo "Backup      : ${BACKUP}"
echo "============================================================"

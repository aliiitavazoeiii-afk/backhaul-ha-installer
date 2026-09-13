#!/usr/bin/env bash
set -Eeuo pipefail

NODE="${1:-}"
case "$NODE" in f1|f2) ;; *) echo "Usage: $0 f1|f2"; exit 2 ;; esac

INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
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
[[ -n "$IPTABLES" ]] || { echo "iptables is required"; exit 1; }

if ss -lntH "( sport = :${NEW_SOCKS} )" 2>/dev/null | grep -q .; then
  echo "Stage port ${NEW_SOCKS} is already in use. If this is an already-staged Vision node, use the existing resume helper instead."
  ss -lntp "( sport = :${NEW_SOCKS} )" || true
  exit 1
fi

prompt() { local var="$1" text="$2" def="${3:-}" val=""; read -r -p "$text${def:+ [$def]}: " val; printf -v "$var" '%s' "${val:-$def}"; }

echo "============================================================"
echo "DUAL IRAN - LIVE MIGRATE ${NODE^^} TO VLESS + REALITY + VISION RAW"
echo "The x-ui routing assignment is NOT changed."
echo "Existing sessions on the old ${NODE^^} SOCKS process are not deliberately closed."
echo "New TCP+UDP connections to 127.0.0.1:${OLD_SOCKS} will be redirected only after the candidate passes."
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
BACKUP="$STATE_DIR/vision-migration-backups/${STAMP}-${NODE}-live"
mkdir -p "$BACKUP"
chmod 700 "$STATE_DIR" "$STATE_DIR/vision-migration-backups" "$BACKUP" 2>/dev/null || true
cp -a "$CONFIG_DIR/config.json" "$BACKUP/config.json"
[[ -f "$VISION_JSON" ]] && cp -a "$VISION_JSON" "$BACKUP/vision.json.old"
[[ -f "$VISION_ENV" ]] && cp -a "$VISION_ENV" "$BACKUP/vision.env.old"
[[ -f "/etc/systemd/system/$VISION_SERVICE" ]] && cp -a "/etc/systemd/system/$VISION_SERVICE" "$BACKUP/vision.service.old"
[[ -f "/etc/systemd/system/$REDIRECT_SERVICE" ]] && cp -a "/etc/systemd/system/$REDIRECT_SERVICE" "$BACKUP/redirect.service.old"
[[ -f "$REDIRECT_HELPER" ]] && cp -a "$REDIRECT_HELPER" "$BACKUP/redirect-helper.old"

XUI_SERVICE="$(python3 - "$CONFIG_DIR/config.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get('xui_service','x-ui'))
PY
)"
XUI_PID_BEFORE="$(systemctl show -p MainPID --value "$XUI_SERVICE" 2>/dev/null || true)"

rollback() {
  echo
  echo "Migration failed; removing redirect and restoring node metadata."
  systemctl disable --now "$REDIRECT_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$REDIRECT_SERVICE" "$REDIRECT_HELPER"
  systemctl daemon-reload || true
  cp -a "$BACKUP/config.json" "$CONFIG_DIR/config.json" || true
  echo "Old ${NODE^^} service was never stopped. Backup: $BACKUP"
}
trap rollback ERR

echo "[1/6] Building candidate Vision client on 127.0.0.1:${NEW_SOCKS}..."
cat >"$TMP/vision.json" <<EOF
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
EOF
python3 -m json.tool "$TMP/vision.json" >/dev/null
"$XRAY" run -test -c "$TMP/vision.json" >/dev/null
install -m 0600 "$TMP/vision.json" "$VISION_JSON"
cat >"$VISION_ENV" <<EOF
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
EOF
chmod 600 "$VISION_ENV"

cat >"/etc/systemd/system/$VISION_SERVICE" <<EOF
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
EOF
systemctl daemon-reload
systemctl enable --now "$VISION_SERVICE"
sleep 2
systemctl is-active --quiet "$VISION_SERVICE"
ss -lntH "( sport = :${NEW_SOCKS} )" | grep -q .
ss -lunH "( sport = :${NEW_SOCKS} )" | grep -q .

echo "[2/6] End-to-end testing candidate before live cutover..."
OK=0
DETAIL=""
for URL in "https://cp.cloudflare.com/generate_204" "https://connectivitycheck.gstatic.com/generate_204" "https://captive.apple.com/hotspot-detect.html"; do
  OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${NEW_SOCKS}" "$URL" 2>/dev/null || true)"
  CODE="${OUT%% *}"; TOTAL="${OUT#* }"; DETAIL="${URL} code=${CODE:-'-'} total=${TOTAL:-'-'}"
  if [[ "$CODE" == "200" || "$CODE" == "204" ]]; then OK=1; echo "Candidate OK: $DETAIL"; break; fi
  echo "Candidate target failed: $DETAIL"
done
(( OK == 1 )) || { echo "Candidate failed. Live ${NODE^^} is unchanged."; exit 1; }
EGRESS="$(curl -fsS --max-time 15 --connect-timeout 5 --socks5-hostname "127.0.0.1:${NEW_SOCKS}" https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
echo "Candidate egress: ${EGRESS:-unknown}"

read -r -p "Candidate passed. Redirect NEW ${NODE^^} TCP+UDP SOCKS connections to Vision? Type YES: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Candidate left staged on ${NEW_SOCKS}; live traffic unchanged."; trap - ERR; exit 0; }

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

echo "[4/6] Verifying the ORIGINAL SOCKS port now reaches Vision..."
OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${OLD_SOCKS}" https://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)"
CODE="${OUT%% *}"
[[ "$CODE" == "200" || "$CODE" == "204" ]] || { echo "Compatibility SOCKS verification failed: $OUT"; false; }
echo "Compatibility SOCKS OK: $OUT"

echo "[5/6] Updating metadata only; user assignments and x-ui routing are untouched..."
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

XUI_PID_AFTER="$(systemctl show -p MainPID --value "$XUI_SERVICE" 2>/dev/null || true)"
if [[ -n "$XUI_PID_BEFORE" && "$XUI_PID_BEFORE" != "0" && "$XUI_PID_BEFORE" != "$XUI_PID_AFTER" ]]; then
  echo "WARNING: x-ui PID changed unexpectedly: $XUI_PID_BEFORE -> $XUI_PID_AFTER"
else
  echo "x-ui PID unchanged: ${XUI_PID_AFTER:-unknown}"
fi

echo "[6/6] Done."
trap - ERR
echo
printf '%s\n' "${NODE^^} LIVE VISION MIGRATION ACTIVE" \
  "Compatibility SOCKS : 127.0.0.1:${OLD_SOCKS} -> Vision ${NEW_SOCKS}" \
  "Vision Foreign      : ${NEW_IP}:${NEW_PORT}" \
  "TCP+UDP redirect    : ACTIVE" \
  "x-ui routing        : unchanged" \
  "Old ${NODE^^} service    : still running for already-established sessions" \
  "Backup              : ${BACKUP}"

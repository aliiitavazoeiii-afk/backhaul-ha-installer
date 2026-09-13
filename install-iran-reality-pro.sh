#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_REF="${PROJECT_REF:-reality-pro}"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${PROJECT_REF}"
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
XRAY_SHA256="${XRAY_SHA256:-}"
INSTALL_DIR="/opt/reality-pro"
CONFIG_DIR="/etc/reality-pro"
STATE_DIR="/var/lib/reality-pro"
DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
FABRIC_SERVICE="reality-pro-fabric.service"
CONTROLLER_SERVICE="reality-pro-controller.service"
API_HOST="127.0.0.1"
API_PORT="${REALITY_PRO_API_PORT:-10085}"
HOME_F1_PORT="${REALITY_PRO_HOME_F1_PORT:-12918}"
HOME_F2_PORT="${REALITY_PRO_HOME_F2_PORT:-12919}"
PROBE_F1_PORT="${REALITY_PRO_PROBE_F1_PORT:-13018}"
PROBE_F2_PORT="${REALITY_PRO_PROBE_F2_PORT:-13019}"
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f "$DB_PATH" ]] || { echo "x-ui SQLite DB not found: $DB_PATH"; exit 1; }
systemctl cat x-ui.service >/dev/null 2>&1 || { echo "x-ui.service not found."; exit 1; }
if [[ -f /etc/xhttp-dual/config.json || -x /usr/local/bin/xhttp-dual ]]; then
  echo "Existing xhttp-dual detected on this Iran server."
  echo "Reality Pro uses separate commands/services, but both would manage x-ui routing."
  echo "Install Reality Pro on a clean/new Iran server or remove xhttp-dual first."
  exit 1
fi
[[ ! -f "$CONFIG_DIR/config.json" ]] || { echo "Reality Pro is already installed. Status: reality-pro status"; exit 1; }
prompt(){ local target="$1" text="$2" def="${3:-}" val=""; read -r -p "$text${def:+ [$def]}: " val; printf -v "$target" '%s' "${val:-$def}"; }
cat <<'TXT'
============================================================
REALITY PRO - IRAN
VLESS + REALITY + Vision RAW
Sticky users + live failover fabric WITHOUT x-ui restart on node failover.
Separate command namespace: reality-pro
============================================================
TXT
prompt F1_IP "Foreign #1 IP/domain"; prompt F1_PORT "Foreign #1 port" "443"; prompt F1_UUID "Foreign #1 VLESS ID"; prompt F1_PASSWORD "Foreign #1 REALITY Password/PublicKey"; prompt F1_SID "Foreign #1 REALITY Short ID"; prompt F1_SNI "Foreign #1 REALITY SNI"; prompt F1_FP "Foreign #1 fingerprint" "chrome"; prompt F1_SPIDER "Foreign #1 spiderX" "/robots.txt"
echo
prompt F2_IP "Foreign #2 IP/domain"; prompt F2_PORT "Foreign #2 port" "443"; prompt F2_UUID "Foreign #2 VLESS ID"; prompt F2_PASSWORD "Foreign #2 REALITY Password/PublicKey"; prompt F2_SID "Foreign #2 REALITY Short ID"; prompt F2_SNI "Foreign #2 REALITY SNI"; prompt F2_FP "Foreign #2 fingerprint" "firefox"; prompt F2_SPIDER "Foreign #2 spiderX" "/favicon.ico"
[[ -n "$F1_IP" && -n "$F2_IP" && "$F1_IP" != "$F2_IP" ]] || { echo "Foreign IPs must be non-empty and different."; exit 1; }
for p in "$F1_PORT" "$F2_PORT" "$API_PORT" "$HOME_F1_PORT" "$HOME_F2_PORT" "$PROBE_F1_PORT" "$PROBE_F2_PORT"; do [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1 && p<=65535 )) || { echo "Invalid port: $p"; exit 1; }; done
for v in "$F1_UUID" "$F1_PASSWORD" "$F1_SID" "$F1_SNI" "$F1_FP" "$F1_SPIDER" "$F2_UUID" "$F2_PASSWORD" "$F2_SID" "$F2_SNI" "$F2_FP" "$F2_SPIDER"; do [[ -n "$v" ]] || { echo "All Foreign credentials/camouflage fields are required."; exit 1; }; done
for p in "$API_PORT" "$HOME_F1_PORT" "$HOME_F2_PORT" "$PROBE_F1_PORT" "$PROBE_F2_PORT"; do if ss -lntH "( sport = :$p )" 2>/dev/null | grep -q .; then echo "Local port $p is already in use:"; ss -lntp "( sport = :$p )" || true; exit 1; fi; done
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl unzip jq ca-certificates iproute2 python3 sqlite3
case "$(dpkg --print-architecture)" in
 amd64) ASSET="Xray-linux-64.zip"; [[ -n "$XRAY_SHA256" ]] || [[ "$XRAY_VERSION" != "v26.3.27" ]] || XRAY_SHA256="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae" ;;
 arm64) ASSET="Xray-linux-arm64-v8a.zip"; [[ -n "$XRAY_SHA256" ]] || [[ "$XRAY_VERSION" != "v26.3.27" ]] || XRAY_SHA256="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c" ;;
 *) echo "Unsupported architecture"; exit 1 ;;
esac
[[ -n "$XRAY_SHA256" ]] || { echo "Set XRAY_SHA256 for a custom Xray version."; exit 1; }
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR/backups"; chmod 700 "$CONFIG_DIR" "$STATE_DIR" "$STATE_DIR/backups"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ASSET}"
echo "[1/11] Installing verified Xray ${XRAY_VERSION}..."
curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 180 "$URL" -o "$TMP/xray.zip"
python3 - "$TMP/xray.zip" "$XRAY_SHA256" <<'PY'
import hashlib,sys
p,e=sys.argv[1:]; g=hashlib.sha256(open(p,'rb').read()).hexdigest()
if g != e: raise SystemExit(f'Xray SHA256 mismatch: {g} != {e}')
print('Xray SHA256 verified:',g)
PY
unzip -q "$TMP/xray.zip" -d "$TMP/xray"; install -m 0755 "$TMP/xray/xray" "$INSTALL_DIR/xray"; "$INSTALL_DIR/xray" version | sed -n '1p'
echo "[2/11] Writing Reality Pro live failover fabric..."
cat >"$CONFIG_DIR/fabric.json" <<FABRIC
{"log":{"loglevel":"warning"},"api":{"tag":"api","services":["RoutingService"]},"inbounds":[{"tag":"api","listen":"${API_HOST}","port":${API_PORT},"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}},{"tag":"rp-home-f1","listen":"127.0.0.1","port":${HOME_F1_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true}},{"tag":"rp-home-f2","listen":"127.0.0.1","port":${HOME_F2_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true}},{"tag":"rp-probe-f1","listen":"127.0.0.1","port":${PROBE_F1_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true}},{"tag":"rp-probe-f2","listen":"127.0.0.1","port":${PROBE_F2_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true}}],"outbounds":[{"tag":"rp-node-f1","protocol":"vless","settings":{"vnext":[{"address":"${F1_IP}","port":${F1_PORT},"users":[{"id":"${F1_UUID}","flow":"xtls-rprx-vision","encryption":"none"}]}]},"streamSettings":{"network":"raw","security":"reality","realitySettings":{"show":false,"fingerprint":"${F1_FP}","serverName":"${F1_SNI}","password":"${F1_PASSWORD}","shortId":"${F1_SID}","spiderX":"${F1_SPIDER}"}}},{"tag":"rp-node-f2","protocol":"vless","settings":{"vnext":[{"address":"${F2_IP}","port":${F2_PORT},"users":[{"id":"${F2_UUID}","flow":"xtls-rprx-vision","encryption":"none"}]}]},"streamSettings":{"network":"raw","security":"reality","realitySettings":{"show":false,"fingerprint":"${F2_FP}","serverName":"${F2_SNI}","password":"${F2_PASSWORD}","shortId":"${F2_SID}","spiderX":"${F2_SPIDER}"}}},{"tag":"direct","protocol":"freedom"}],"routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","inboundTag":["rp-probe-f1"],"outboundTag":"rp-node-f1"},{"type":"field","inboundTag":["rp-probe-f2"],"outboundTag":"rp-node-f2"},{"type":"field","inboundTag":["rp-home-f1"],"balancerTag":"rp-home-f1-bal"},{"type":"field","inboundTag":["rp-home-f2"],"balancerTag":"rp-home-f2-bal"}],"balancers":[{"tag":"rp-home-f1-bal","selector":["rp-node-"],"strategy":{"type":"random"}},{"tag":"rp-home-f2-bal","selector":["rp-node-"],"strategy":{"type":"random"}}]}}
FABRIC
chmod 600 "$CONFIG_DIR/fabric.json"; jq empty "$CONFIG_DIR/fabric.json"; "$INSTALL_DIR/xray" run -test -c "$CONFIG_DIR/fabric.json" >/dev/null
cat >"$CONFIG_DIR/foreign1.env" <<E1
FOREIGN_IP='${F1_IP}'
PORT='${F1_PORT}'
VLESS_ID='${F1_UUID}'
REALITY_PASSWORD='${F1_PASSWORD}'
REALITY_SHORT_ID='${F1_SID}'
SNI='${F1_SNI}'
FINGERPRINT='${F1_FP}'
SPIDER_X='${F1_SPIDER}'
E1
cat >"$CONFIG_DIR/foreign2.env" <<E2
FOREIGN_IP='${F2_IP}'
PORT='${F2_PORT}'
VLESS_ID='${F2_UUID}'
REALITY_PASSWORD='${F2_PASSWORD}'
REALITY_SHORT_ID='${F2_SID}'
SNI='${F2_SNI}'
FINGERPRINT='${F2_FP}'
SPIDER_X='${F2_SPIDER}'
E2
chmod 600 "$CONFIG_DIR"/*.env
echo "[3/11] Installing isolated fabric service..."
cat >"/etc/systemd/system/$FABRIC_SERVICE" <<UNIT
[Unit]
Description=Reality Pro live failover fabric
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xray run -c ${CONFIG_DIR}/fabric.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload; systemctl enable --now "$FABRIC_SERVICE"; sleep 2; systemctl is-active --quiet "$FABRIC_SERVICE"
for p in "$API_PORT" "$HOME_F1_PORT" "$HOME_F2_PORT" "$PROBE_F1_PORT" "$PROBE_F2_PORT"; do ss -lntH "( sport = :$p )" | grep -q . || { echo "Fabric TCP port $p did not start"; exit 1; }; done
API_ADDR="${API_HOST}:${API_PORT}"
echo "[4/11] Pinning stable home F1/F2 balancers..."
"$INSTALL_DIR/xray" api bo --server="$API_ADDR" -b rp-home-f1-bal rp-node-f1 >/dev/null
"$INSTALL_DIR/xray" api bo --server="$API_ADDR" -b rp-home-f2-bal rp-node-f2 >/dev/null
probe_path(){ local label="$1" port="$2" code ip; code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${port}" https://cp.cloudflare.com/generate_204 2>/dev/null || true)"; [[ "$code" == 204 || "$code" == 200 ]] || { echo "$label health failed: HTTP ${code:-000}"; return 1; }; ip="$(curl -fsS --max-time 15 --connect-timeout 5 --socks5-hostname "127.0.0.1:${port}" https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"; [[ -n "$ip" ]] || { echo "$label egress lookup failed"; return 1; }; echo "$label OK: egress=$ip"; }
echo "[5/11] End-to-end testing both Foreign paths BEFORE x-ui changes..."; probe_path F1 "$PROBE_F1_PORT"; probe_path F2 "$PROBE_F2_PORT"
echo "[6/11] Installing Reality Pro controller..."
curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 "$BASE_URL/reality-pro-controller.py" -o "$INSTALL_DIR/controller.py"; chmod 0755 "$INSTALL_DIR/controller.py"; python3 -m py_compile "$INSTALL_DIR/controller.py"
cat >"$CONFIG_DIR/config.json" <<CFG
{"db_path":"${DB_PATH}","xui_service":"x-ui","xray_bin":"${INSTALL_DIR}/xray","api_listen":"${API_ADDR}","home_ports":{"f1":${HOME_F1_PORT},"f2":${HOME_F2_PORT}},"probe_ports":{"f1":${PROBE_F1_PORT},"f2":${PROBE_F2_PORT}},"healthy_probe_min_s":75,"healthy_probe_max_s":180,"unhealthy_probe_min_s":15,"unhealthy_probe_max_s":35,"controller_tick_min_s":5,"controller_tick_max_s":12,"health_timeout_s":12,"failure_threshold":3,"recovery_threshold":3,"user_sync_interval_s":60,"health_urls":["https://cp.cloudflare.com/generate_204","https://connectivitycheck.gstatic.com/generate_204","https://captive.apple.com/hotspot-detect.html"],"nodes":{"f1":{"foreign_ip":"${F1_IP}","foreign_port":${F1_PORT}},"f2":{"foreign_ip":"${F2_IP}","foreign_port":${F2_PORT}}}}
CFG
chmod 600 "$CONFIG_DIR/config.json"
cat >/usr/local/bin/reality-pro <<CLI
#!/bin/sh
exec /usr/bin/python3 ${INSTALL_DIR}/controller.py "\$@"
CLI
chmod 0755 /usr/local/bin/reality-pro
echo "[7/11] Ensuring x-ui template storage exists with Reality Pro backup path..."
if ! sqlite3 "$DB_PATH" "SELECT 1 FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;" 2>/dev/null | grep -qx 1; then
 RUNTIME_CONFIG="${XUI_RUNTIME_CONFIG:-/usr/local/x-ui/bin/config.json}"; [[ -f "$RUNTIME_CONFIG" ]] || { echo "Missing x-ui runtime config: $RUNTIME_CONFIG"; exit 1; }; STAMP="$(date +%Y%m%d-%H%M%S)"; sqlite3 "$DB_PATH" ".backup '$STATE_DIR/backups/x-ui-before-template-bootstrap-$STAMP.db'"
 python3 - "$DB_PATH" "$RUNTIME_CONFIG" "$TMP/bootstrap-template.json" <<'PY'
import json,sqlite3,sys
p,runtime,out=sys.argv[1:]; obj=json.load(open(runtime,encoding='utf-8')); con=sqlite3.connect(p); tags={str(x[0]).strip() for x in con.execute("SELECT tag FROM inbounds WHERE tag IS NOT NULL AND trim(tag)<>''")}; con.close(); obj['inbounds']=[i for i in (obj.get('inbounds') or []) if not (isinstance(i,dict) and str(i.get('tag') or '').strip() in tags)]; json.dump(obj,open(out,'w',encoding='utf-8'),separators=(',',':'))
PY
 python3 - "$DB_PATH" "$TMP/bootstrap-template.json" <<'PY'
import sqlite3,sys
p,f=sys.argv[1:]; v=open(f,encoding='utf-8').read(); con=sqlite3.connect(p,timeout=15); con.execute('BEGIN IMMEDIATE'); con.execute("INSERT INTO settings(key,value) VALUES(?,?)",('xrayTemplateConfig',v)); con.commit(); con.close()
PY
fi
echo "[8/11] Installing controller service..."
cat >"/etc/systemd/system/$CONTROLLER_SERVICE" <<UNIT
[Unit]
Description=Reality Pro sticky routing and live failover controller
After=network-online.target x-ui.service ${FABRIC_SERVICE}
Wants=network-online.target
Requires=${FABRIC_SERVICE}
[Service]
Type=simple
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/controller.py daemon
Restart=always
RestartSec=3
Nice=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
echo "[9/11] Applying initial per-user sticky map to stable home ports..."; reality-pro sync
echo "[10/11] Starting automatic Reality Pro controller..."; systemctl enable --now "$CONTROLLER_SERVICE"; sleep 2; systemctl is-active --quiet "$CONTROLLER_SERVICE"
echo "[11/11] Final verification..."; reality-pro status; echo; reality-pro diagnose; echo; reality-pro netcheck
cat <<DONE
============================================================
REALITY PRO READY
CLI          : reality-pro status|diagnose|netcheck|sync|drain|undrain|rebalance
Home F1      : 127.0.0.1:${HOME_F1_PORT}
Home F2      : 127.0.0.1:${HOME_F2_PORT}
Probe F1     : 127.0.0.1:${PROBE_F1_PORT}
Probe F2     : 127.0.0.1:${PROBE_F2_PORT}
Fabric API   : ${API_ADDR}
Failover     : live balancer override; NO x-ui restart on node health failover
User changes : x-ui may restart only when the sticky user map itself changes
============================================================
DONE

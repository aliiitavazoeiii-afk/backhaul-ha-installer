#!/usr/bin/env bash
set -Eeuo pipefail

XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/xhttp-dual-sticky-failover"
INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
SOCKS1="${SOCKS1:-11818}"
SOCKS2="${SOCKS2:-11819}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
RECOVERY_THRESHOLD="${RECOVERY_THRESHOLD:-5}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

prompt() {
  local var="$1" text="$2" def="${3:-}" secret="${4:-0}" val=""
  if declare -p "$var" >/dev/null 2>&1; then
    val="${!var}"
  fi
  if [[ -z "$val" ]]; then
    if [[ "$secret" == "1" ]]; then
      read -r -s -p "$text${def:+ [$def]}: " val; echo
    else
      read -r -p "$text${def:+ [$def]}: " val
    fi
    val="${val:-$def}"
    printf -v "$var" '%s' "$val"
  fi
}

cat <<'EOF'
============================================================
XHTTP DUAL FOREIGN - STICKY USER FAILOVER (IRAN)
Two independent XHTTP+REALITY paths + per-VLESS-user sticky routing.
Existing single XHTTP/Mieru/FRP services are NOT removed.
============================================================
EOF

prompt F1_IP "Foreign #1 IP/domain"
prompt F1_PORT "Foreign #1 port" "443"
prompt F1_VLESS_ID "Foreign #1 VLESS ID"
prompt F1_REALITY_PASSWORD "Foreign #1 REALITY Password/PublicKey"
prompt F1_SHORT_ID "Foreign #1 Short ID"
prompt F1_SNI "Foreign #1 REALITY SNI" "www.cloudflare.com"
prompt F1_PATH "Foreign #1 XHTTP Path"

echo
prompt F2_IP "Foreign #2 IP/domain"
prompt F2_PORT "Foreign #2 port" "443"
prompt F2_VLESS_ID "Foreign #2 VLESS ID"
prompt F2_REALITY_PASSWORD "Foreign #2 REALITY Password/PublicKey"
prompt F2_SHORT_ID "Foreign #2 Short ID"
prompt F2_SNI "Foreign #2 REALITY SNI" "www.cloudflare.com"
prompt F2_PATH "Foreign #2 XHTTP Path"

[[ "$F1_IP" != "$F2_IP" ]] || { echo "Foreign #1 and #2 must be different."; exit 1; }
[[ -f "$DB_PATH" ]] || { echo "x-ui SQLite DB not found: $DB_PATH"; exit 1; }
systemctl cat x-ui.service >/dev/null 2>&1 || { echo "x-ui.service not found."; exit 1; }

for p in "$SOCKS1" "$SOCKS2"; do
  [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 && p < 65536 )) || { echo "Invalid SOCKS port: $p"; exit 1; }
  if ss -lntH "( sport = :$p )" 2>/dev/null | grep -q .; then
    echo "Local TCP port $p is already in use:"; ss -lntp "( sport = :$p )" || true; exit 1
  fi
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl unzip jq ca-certificates iproute2 python3 sqlite3

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) ASSET="Xray-linux-64.zip" ;;
  arm64) ASSET="Xray-linux-arm64-v8a.zip" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ASSET}"
echo "[1/8] Installing Xray ${XRAY_VERSION}..."
curl -fL --retry 5 --retry-delay 2 --connect-timeout 15 "$URL" -o "$TMP/xray.zip"
unzip -q "$TMP/xray.zip" -d "$TMP/xray"
install -m 0755 "$TMP/xray/xray" "$INSTALL_DIR/xray"
"$INSTALL_DIR/xray" version | sed -n '1p'

write_client() {
  local name="$1" socks="$2" ip="$3" port="$4" uuid="$5" pub="$6" sid="$7" sni="$8" path="$9"
  cat >"$CONFIG_DIR/${name}.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "local-socks-${name}",
    "listen": "127.0.0.1",
    "port": ${socks},
    "protocol": "socks",
    "settings": {"auth": "noauth", "udp": true}
  }],
  "outbounds": [{
    "tag": "xhttp-${name}",
    "protocol": "vless",
    "settings": {"vnext": [{"address": "${ip}", "port": ${port}, "users": [{"id": "${uuid}", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "xhttpSettings": {"mode": "auto", "path": "${path}"},
      "realitySettings": {"serverName": "${sni}", "fingerprint": "chrome", "publicKey": "${pub}", "shortId": "${sid}"}
    },
    "mux": {"enabled": true, "concurrency": -1, "xudpConcurrency": 16, "xudpProxyUDP443": "allow"}
  }]
}
EOF
  chmod 600 "$CONFIG_DIR/${name}.json"
  jq empty "$CONFIG_DIR/${name}.json"
  "$INSTALL_DIR/xray" run -test -c "$CONFIG_DIR/${name}.json" >/dev/null
}

echo "[2/8] Writing two independent XHTTP clients..."
write_client f1 "$SOCKS1" "$F1_IP" "$F1_PORT" "$F1_VLESS_ID" "$F1_REALITY_PASSWORD" "$F1_SHORT_ID" "$F1_SNI" "$F1_PATH"
write_client f2 "$SOCKS2" "$F2_IP" "$F2_PORT" "$F2_VLESS_ID" "$F2_REALITY_PASSWORD" "$F2_SHORT_ID" "$F2_SNI" "$F2_PATH"

cat >"$CONFIG_DIR/foreign1.env" <<EOF
FOREIGN_IP='${F1_IP}'
PORT='${F1_PORT}'
VLESS_ID='${F1_VLESS_ID}'
REALITY_PASSWORD='${F1_REALITY_PASSWORD}'
REALITY_SHORT_ID='${F1_SHORT_ID}'
SNI='${F1_SNI}'
XHTTP_PATH='${F1_PATH}'
SOCKS_PORT='${SOCKS1}'
EOF
cat >"$CONFIG_DIR/foreign2.env" <<EOF
FOREIGN_IP='${F2_IP}'
PORT='${F2_PORT}'
VLESS_ID='${F2_VLESS_ID}'
REALITY_PASSWORD='${F2_REALITY_PASSWORD}'
REALITY_SHORT_ID='${F2_SHORT_ID}'
SNI='${F2_SNI}'
XHTTP_PATH='${F2_PATH}'
SOCKS_PORT='${SOCKS2}'
EOF
chmod 600 "$CONFIG_DIR"/*.env

install_service() {
  local name="$1"
  cat >"/etc/systemd/system/xhttp-dual-${name}.service" <<EOF
[Unit]
Description=XHTTP Dual Sticky client ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xray run -c ${CONFIG_DIR}/${name}.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF
}

echo "[3/8] Installing tunnel services..."
install_service f1
install_service f2
systemctl daemon-reload
systemctl enable --now xhttp-dual-f1.service xhttp-dual-f2.service
sleep 2

for p in "$SOCKS1" "$SOCKS2"; do
  ss -lntH "( sport = :$p )" | grep -q . || { echo "SOCKS $p did not start"; exit 1; }
done

echo "[4/8] End-to-end testing both foreign paths..."
test_path() {
  local label="$1" socks="$2"
  local ip
  ip="$(curl -fsS --max-time 20 --connect-timeout 8 --socks5-hostname "127.0.0.1:${socks}" https://icanhazip.com | tr -d '[:space:]')" || return 1
  echo "${label} egress: ${ip}"
}
test_path F1 "$SOCKS1" || { echo "Foreign #1 tunnel test FAILED"; exit 1; }
test_path F2 "$SOCKS2" || { echo "Foreign #2 tunnel test FAILED"; exit 1; }

echo "[5/8] Installing sticky/failover controller..."
curl -fsSL "${BASE_URL}/dual-controller.py" -o "$INSTALL_DIR/controller.py"
chmod 0755 "$INSTALL_DIR/controller.py"
python3 -m py_compile "$INSTALL_DIR/controller.py"

cat >"$CONFIG_DIR/config.json" <<EOF
{
  "db_path": "${DB_PATH}",
  "xui_service": "x-ui",
  "check_interval": ${CHECK_INTERVAL},
  "failure_threshold": ${FAILURE_THRESHOLD},
  "recovery_threshold": ${RECOVERY_THRESHOLD},
  "managed_fallback": true,
  "nodes": {
    "f1": {"foreign_ip": "${F1_IP}", "socks_host": "127.0.0.1", "socks_port": ${SOCKS1}, "health_url": "https://cp.cloudflare.com/generate_204", "health_timeout": 8},
    "f2": {"foreign_ip": "${F2_IP}", "socks_host": "127.0.0.1", "socks_port": ${SOCKS2}, "health_url": "https://cp.cloudflare.com/generate_204", "health_timeout": 8}
  }
}
EOF
chmod 600 "$CONFIG_DIR/config.json"

cat >/usr/local/bin/xhttp-dual <<'EOF'
#!/bin/sh
exec /usr/bin/python3 /opt/xhttp-dual/controller.py "$@"
EOF
chmod 0755 /usr/local/bin/xhttp-dual

cat >/etc/systemd/system/xhttp-dual-controller.service <<EOF
[Unit]
Description=XHTTP Dual Sticky User Load Balancer and Failover Controller
After=network-online.target x-ui.service xhttp-dual-f1.service xhttp-dual-f2.service
Wants=network-online.target
Requires=xhttp-dual-f1.service xhttp-dual-f2.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/controller.py daemon
Restart=always
RestartSec=3
Nice=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

echo "[6/8] Initial sticky 50/50 user mapping + safe x-ui patch..."
/usr/local/bin/xhttp-dual sync

echo "[7/8] Starting automatic failover controller..."
systemctl enable --now xhttp-dual-controller.service
sleep 2

cat >/etc/sysctl.d/99-xhttp-dual-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1 || true

echo "[8/8] Final status..."
/usr/local/bin/xhttp-dual status

echo
cat <<EOF
============================================================
XHTTP DUAL STICKY FAILOVER READY
F1            : ${F1_IP}:${F1_PORT} -> 127.0.0.1:${SOCKS1}
F2            : ${F2_IP}:${F2_PORT} -> 127.0.0.1:${SOCKS2}
User policy   : persistent per-email 50/50 assignment
Failover      : 3 failures by default; moved users stay on survivor
Recovery      : no automatic move-back (prevents IP flip/flapping)
Controller    : xhttp-dual-controller.service
CLI           : xhttp-dual status|sync|drain|undrain|rebalance
State         : ${STATE_DIR}/state.json
x-ui DB       : ${DB_PATH} (backup before every managed write)
============================================================
EOF

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_REF="${PROJECT_REF:-xhttp-dual-sticky-failover}"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${PROJECT_REF}"
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
XRAY_SHA256="${XRAY_SHA256:-}"
INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
SOCKS1="${SOCKS1:-12818}"
SOCKS2="${SOCKS2:-12819}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

prompt() {
  local target="$1" text="$2" def="${3:-}" val=""
  read -r -p "$text${def:+ [$def]}: " val
  printf -v "$target" '%s' "${val:-$def}"
}

[[ -f "$DB_PATH" ]] || { echo "x-ui SQLite DB not found: $DB_PATH"; exit 1; }
systemctl cat x-ui.service >/dev/null 2>&1 || { echo "x-ui.service not found."; exit 1; }

if [[ -f "$CONFIG_DIR/config.json" ]]; then
  echo "Dual tunnel is already installed on this Iran server."
  echo "Refusing fresh overwrite."
  echo "Current status: xhttp-dual status"
  exit 1
fi

for p in "$SOCKS1" "$SOCKS2"; do
  if ss -lntH "( sport = :$p )" 2>/dev/null | grep -q .; then
    echo "Local port $p is already in use:"; ss -lntp "( sport = :$p )" || true; exit 1
  fi
done

cat <<'EOF'
============================================================
IRAN DUAL VISION - VLESS + REALITY + XTLS VISION RAW
Two independent Foreign nodes + per-user sticky routing/failover.
No XHTTP. No iptables redirect. Direct SOCKS backends.
Requires an existing x-ui install and VLESS users on this Iran server.
============================================================
EOF

prompt F1_IP "Foreign #1 IP/domain"
prompt F1_PORT "Foreign #1 port" "443"
prompt F1_UUID "Foreign #1 VLESS ID"
prompt F1_PASSWORD "Foreign #1 REALITY Password/PublicKey"
prompt F1_SID "Foreign #1 REALITY Short ID"
prompt F1_SNI "Foreign #1 REALITY SNI" "dl.google.com"

echo
prompt F2_IP "Foreign #2 IP/domain"
prompt F2_PORT "Foreign #2 port" "443"
prompt F2_UUID "Foreign #2 VLESS ID"
prompt F2_PASSWORD "Foreign #2 REALITY Password/PublicKey"
prompt F2_SID "Foreign #2 REALITY Short ID"
prompt F2_SNI "Foreign #2 REALITY SNI" "dl.google.com"

[[ -n "$F1_IP" && -n "$F2_IP" && "$F1_IP" != "$F2_IP" ]] || { echo "Foreign #1/#2 must be non-empty and different."; exit 1; }
for p in "$F1_PORT" "$F2_PORT"; do
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || { echo "Invalid Foreign port: $p"; exit 1; }
done
for v in "$F1_UUID" "$F1_PASSWORD" "$F1_SID" "$F1_SNI" "$F2_UUID" "$F2_PASSWORD" "$F2_SID" "$F2_SNI"; do
  [[ -n "$v" ]] || { echo "All Foreign credentials are required."; exit 1; }
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl unzip jq ca-certificates iproute2 python3 sqlite3

case "$(dpkg --print-architecture)" in
  amd64)
    ASSET="Xray-linux-64.zip"
    [[ -n "$XRAY_SHA256" ]] || [[ "$XRAY_VERSION" != "v26.3.27" ]] || XRAY_SHA256="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
    ;;
  arm64)
    ASSET="Xray-linux-arm64-v8a.zip"
    [[ -n "$XRAY_SHA256" ]] || [[ "$XRAY_VERSION" != "v26.3.27" ]] || XRAY_SHA256="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"
    ;;
  *) echo "Unsupported architecture"; exit 1 ;;
esac
[[ -n "$XRAY_SHA256" ]] || { echo "Set XRAY_SHA256 for custom Xray version."; exit 1; }

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ASSET}"
echo "[1/10] Installing verified Xray ${XRAY_VERSION}..."
curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 180 "$URL" -o "$TMP/xray.zip"
python3 - "$TMP/xray.zip" "$XRAY_SHA256" <<'PY'
import hashlib,sys
p,e=sys.argv[1:]
g=hashlib.sha256(open(p,'rb').read()).hexdigest()
if g != e: raise SystemExit(f'Xray SHA256 mismatch: {g} != {e}')
print('Xray SHA256 verified:', g)
PY
unzip -q "$TMP/xray.zip" -d "$TMP/xray"
install -m 0755 "$TMP/xray/xray" "$INSTALL_DIR/xray"
"$INSTALL_DIR/xray" version | sed -n '1p'

write_vision_client() {
  local node="$1" socks="$2" ip="$3" port="$4" uuid="$5" pass="$6" sid="$7" sni="$8"
  cat >"$CONFIG_DIR/${node}.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "local-socks-${node}-vision",
    "listen": "127.0.0.1",
    "port": ${socks},
    "protocol": "socks",
    "settings": {"auth": "noauth", "udp": true}
  }],
  "outbounds": [{
    "tag": "vision-${node}",
    "protocol": "vless",
    "settings": {"vnext": [{"address": "${ip}", "port": ${port}, "users": [{"id": "${uuid}", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {"show": false, "fingerprint": "chrome", "serverName": "${sni}", "password": "${pass}", "shortId": "${sid}", "spiderX": "/"}
    }
  }]
}
EOF
  chmod 600 "$CONFIG_DIR/${node}.json"
  jq empty "$CONFIG_DIR/${node}.json"
  "$INSTALL_DIR/xray" run -test -c "$CONFIG_DIR/${node}.json" >/dev/null
}

echo "[2/10] Writing direct Vision clients..."
write_vision_client f1 "$SOCKS1" "$F1_IP" "$F1_PORT" "$F1_UUID" "$F1_PASSWORD" "$F1_SID" "$F1_SNI"
write_vision_client f2 "$SOCKS2" "$F2_IP" "$F2_PORT" "$F2_UUID" "$F2_PASSWORD" "$F2_SID" "$F2_SNI"

cat >"$CONFIG_DIR/foreign1.env" <<EOF
FOREIGN_IP='${F1_IP}'
PORT='${F1_PORT}'
VLESS_ID='${F1_UUID}'
REALITY_PASSWORD='${F1_PASSWORD}'
REALITY_SHORT_ID='${F1_SID}'
SNI='${F1_SNI}'
FLOW='xtls-rprx-vision'
TRANSPORT='raw'
SOCKS_PORT='${SOCKS1}'
EOF
cat >"$CONFIG_DIR/foreign2.env" <<EOF
FOREIGN_IP='${F2_IP}'
PORT='${F2_PORT}'
VLESS_ID='${F2_UUID}'
REALITY_PASSWORD='${F2_PASSWORD}'
REALITY_SHORT_ID='${F2_SID}'
SNI='${F2_SNI}'
FLOW='xtls-rprx-vision'
TRANSPORT='raw'
SOCKS_PORT='${SOCKS2}'
EOF
chmod 600 "$CONFIG_DIR"/*.env

install_tunnel_service() {
  local node="$1"
  cat >"/etc/systemd/system/xhttp-dual-${node}.service" <<EOF
[Unit]
Description=Dual ${node^^} VLESS REALITY Vision client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xray run -c ${CONFIG_DIR}/${node}.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF
}

echo "[3/10] Installing both Vision tunnel services..."
install_tunnel_service f1
install_tunnel_service f2
systemctl daemon-reload
systemctl enable --now xhttp-dual-f1.service xhttp-dual-f2.service
sleep 2
for p in "$SOCKS1" "$SOCKS2"; do
  ss -lntH "( sport = :$p )" | grep -q . || { echo "SOCKS $p did not start"; exit 1; }
  ss -lunH "( sport = :$p )" | grep -q . || { echo "UDP SOCKS $p did not start"; exit 1; }
done

echo "[4/10] End-to-end testing both Vision paths BEFORE x-ui changes..."
test_path() {
  local label="$1" socks="$2" expected="$3"
  local code ip
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${socks}" https://cp.cloudflare.com/generate_204 2>/dev/null || true)"
  [[ "$code" == "204" || "$code" == "200" ]] || { echo "$label health failed: HTTP ${code:-000}"; return 1; }
  ip="$(curl -fsS --max-time 15 --connect-timeout 5 --socks5-hostname "127.0.0.1:${socks}" https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$ip" ]] || { echo "$label egress lookup failed"; return 1; }
  echo "$label OK: egress=$ip foreign=$expected"
}
test_path F1 "$SOCKS1" "$F1_IP"
test_path F2 "$SOCKS2" "$F2_IP"

echo "[5/10] Installing sticky/failover controller stack..."
for f in dual-controller.py dual-controller-v2.py dual-controller-v3.py dual-controller-v4.py; do
  curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 "$BASE_URL/$f" -o "$TMP/$f"
done
install -m 0755 "$TMP/dual-controller.py" "$INSTALL_DIR/controller.py"
install -m 0755 "$TMP/dual-controller-v2.py" "$INSTALL_DIR/controller-v2.py"
install -m 0755 "$TMP/dual-controller-v3.py" "$INSTALL_DIR/controller-v3.py"
install -m 0755 "$TMP/dual-controller-v4.py" "$INSTALL_DIR/controller-v4.py"
python3 -m py_compile "$INSTALL_DIR/controller.py" "$INSTALL_DIR/controller-v2.py" "$INSTALL_DIR/controller-v3.py" "$INSTALL_DIR/controller-v4.py"

cat >"$CONFIG_DIR/config.json" <<EOF
{
  "db_path": "${DB_PATH}",
  "xui_service": "x-ui",
  "check_interval": 18,
  "healthy_probe_interval": 18,
  "unhealthy_probe_interval": 10,
  "probe_jitter_min": 0.55,
  "probe_jitter_max": 1.75,
  "controller_tick_min": 5,
  "controller_tick_max": 12,
  "failure_threshold": 3,
  "slow_failure_threshold": 2,
  "recovery_threshold": 5,
  "managed_fallback": true,
  "nodes": {
    "f1": {
      "foreign_ip": "${F1_IP}", "foreign_port": ${F1_PORT},
      "transport": "vision-raw", "socks_host": "127.0.0.1", "socks_port": ${SOCKS1},
      "health_url": "https://cp.cloudflare.com/generate_204",
      "health_urls": ["https://cp.cloudflare.com/generate_204", "https://connectivitycheck.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"],
      "health_timeout": 8, "max_latency_ms": 1500
    },
    "f2": {
      "foreign_ip": "${F2_IP}", "foreign_port": ${F2_PORT},
      "transport": "vision-raw", "socks_host": "127.0.0.1", "socks_port": ${SOCKS2},
      "health_url": "https://cp.cloudflare.com/generate_204",
      "health_urls": ["https://cp.cloudflare.com/generate_204", "https://connectivitycheck.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"],
      "health_timeout": 8, "max_latency_ms": 1500
    }
  }
}
EOF
chmod 600 "$CONFIG_DIR/config.json"

cat >"$STATE_DIR/state.json" <<EOF
{
  "version": 1,
  "rr_next": "f1",
  "users": {},
  "nodes": {
    "f1": {"healthy": true, "failures": 0, "slow_failures": 0, "successes": 1, "drained": false, "last_change": null, "last_check": null},
    "f2": {"healthy": true, "failures": 0, "slow_failures": 0, "successes": 1, "drained": false, "last_change": null, "last_check": null}
  },
  "last_apply": null,
  "last_error": null
}
EOF
chmod 600 "$STATE_DIR/state.json"

cat >/usr/local/bin/xhttp-dual <<'EOF'
#!/bin/sh
exec /usr/bin/python3 /opt/xhttp-dual/controller-v4.py "$@"
EOF
chmod 0755 /usr/local/bin/xhttp-dual

cat >/etc/systemd/system/xhttp-dual-controller.service <<EOF
[Unit]
Description=Dual Vision Sticky User Load Balancer and Failover Controller
After=network-online.target x-ui.service xhttp-dual-f1.service xhttp-dual-f2.service
Wants=network-online.target
Requires=xhttp-dual-f1.service xhttp-dual-f2.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/controller-v4.py daemon
Restart=always
RestartSec=3
Nice=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

echo "[6/10] Ensuring x-ui template storage exists..."
if ! sqlite3 "$DB_PATH" "SELECT 1 FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;" 2>/dev/null | grep -qx 1; then
  curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 "$BASE_URL/fix-xui-template.sh" -o "$TMP/fix-xui-template.sh"
  chmod +x "$TMP/fix-xui-template.sh"
  "$TMP/fix-xui-template.sh"
fi

echo "[7/10] Applying initial 50/50 sticky routing (x-ui restarts once here)..."
/usr/local/bin/xhttp-dual sync

echo "[8/10] Starting automatic controller..."
systemctl enable --now xhttp-dual-controller.service
sleep 3
systemctl is-active --quiet xhttp-dual-controller.service

cat >/etc/sysctl.d/99-xhttp-dual-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1 || true

echo "[9/10] Runtime checks..."
xhttp-dual status
xhttp-dual diagnose
xhttp-dual netcheck

echo "[10/10] Done."
echo
cat <<EOF
============================================================
IRAN DUAL VISION READY
F1 : 127.0.0.1:${SOCKS1} -> ${F1_IP}:${F1_PORT}
F2 : 127.0.0.1:${SOCKS2} -> ${F2_IP}:${F2_PORT}
Mode: VLESS + REALITY + xtls-rprx-vision + RAW
User policy: persistent per-email sticky assignment, approximately 50/50
Failover: automatic; home assignment is preserved for recovery
CLI: xhttp-dual status | diagnose | netcheck | drain f1|f2 | undrain f1|f2
No XHTTP and no iptables redirect are used.
============================================================
EOF

#!/usr/bin/env bash
set -Eeuo pipefail

APP="maya-failover"
ETC="/etc/${APP}"
STATE="/var/lib/${APP}"
OPT="/opt/${APP}"
BIN="${OPT}/bin"
SERVICE="${APP}.service"
CONTROLLER_COMMIT="5cf549aa2196bb079df66b379b18a36f085ce1bc"
CONTROLLER_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${CONTROLLER_COMMIT}/maya-failover-controller/controller-vless.py"
XRAY_VERSION="v26.7.28"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -r "$ETC/config.json" ]] || { echo "Missing $ETC/config.json" >&2; exit 1; }
[[ -r "$ETC/secrets.env" ]] || { echo "Missing $ETC/secrets.env" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y ca-certificates curl jq unzip python3 >/dev/null

printf 'Paste MAYA1 VLESS URL: '
read -r -s MAYA1_VLESS
echo
printf 'Paste MAYA3 VLESS URL: '
read -r -s MAYA3_VLESS
echo
[[ "$MAYA1_VLESS" == vless://* ]] || { echo "MAYA1 value is not a vless:// URL" >&2; exit 1; }
[[ "$MAYA3_VLESS" == vless://* ]] || { echo "MAYA3 value is not a vless:// URL" >&2; exit 1; }

mkdir -p "$STATE/backups" "$BIN"
chmod 0700 "$ETC" "$STATE" "$STATE/backups"
TS="$(date +%Y%m%d-%H%M%S)"
tar -czf "$STATE/backups/pre-vless-monitor-${TS}.tar.gz" \
  "$ETC/config.json" "$ETC/secrets.env" \
  "$STATE/state.json" "/opt/maya-failover/controller.py" \
  "/etc/systemd/system/${SERVICE}" 2>/dev/null || true
chmod 0600 "$STATE/backups/pre-vless-monitor-${TS}.tar.gz" 2>/dev/null || true
echo "Backup: $STATE/backups/pre-vless-monitor-${TS}.tar.gz"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
  aarch64|arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
  *) echo "Unsupported management-server architecture: $ARCH" >&2; exit 1 ;;
esac

TMP_ZIP="$(mktemp)"
TMP_CFG="$(mktemp)"
TMP_CONTROLLER="$(mktemp)"
trap 'rm -f "$TMP_ZIP" "$TMP_CFG" "$TMP_CONTROLLER"' EXIT
curl -fL --retry 4 --retry-delay 2 \
  "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_ASSET}" \
  -o "$TMP_ZIP"
unzip -p "$TMP_ZIP" xray > "$BIN/xray"
chmod 0755 "$BIN/xray"
"$BIN/xray" version | head -n 1

cat >"$ETC/vless.env" <<EOF
MAYA1_VLESS=${MAYA1_VLESS}
MAYA3_VLESS=${MAYA3_VLESS}
EOF
chmod 0600 "$ETC/vless.env"
unset MAYA1_VLESS MAYA3_VLESS

jq '
{
  cloudflare: .cloudflare,
  policy: {
    interval_seconds: 15,
    active_failures_before_switch: 3
  },
  services: {
    maya1: {
      domain: .services.maya1.domain,
      record_id: .services.maya1.record_id,
      main_iran_ip: .services.maya1.main_iran_ip,
      spare_iran_ip: .services.maya1.spare_iran_ip
    },
    maya3: {
      domain: .services.maya3.domain,
      record_id: .services.maya3.record_id,
      main_iran_ip: .services.maya3.main_iran_ip,
      spare_iran_ip: .services.maya3.spare_iran_ip
    }
  }
}
' "$ETC/config.json" > "$TMP_CFG"

for key in \
  '.cloudflare.zone_id' \
  '.services.maya1.record_id' '.services.maya1.main_iran_ip' '.services.maya1.spare_iran_ip' \
  '.services.maya3.record_id' '.services.maya3.main_iran_ip' '.services.maya3.spare_iran_ip'; do
  v="$(jq -r "$key // empty" "$TMP_CFG")"
  [[ -n "$v" ]] || { echo "Missing required config value: $key" >&2; exit 1; }
done
install -m 0600 "$TMP_CFG" "$ETC/config.json"

curl -fsSL --retry 4 "$CONTROLLER_URL" -o "$TMP_CONTROLLER"
python3 -m py_compile "$TMP_CONTROLLER"
install -m 0755 "$TMP_CONTROLLER" "$OPT/controller.py"

# Keep Telegram update offset, but discard all old health/probe state.
OLD_OFFSET=0
if [[ -r "$STATE/state.json" ]]; then
  OLD_OFFSET="$(jq -r '.telegram_offset // 0' "$STATE/state.json" 2>/dev/null || echo 0)"
fi
cat >"$STATE/state.json" <<EOF
{
  "services": {},
  "telegram_offset": ${OLD_OFFSET}
}
EOF
chmod 0600 "$STATE/state.json"

cat >"/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=Maya1/Maya3 full VLESS Reality Cloudflare Failover Controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${OPT}/controller.py
Restart=always
RestartSec=5
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RuntimeDirectory=maya-failover
RuntimeDirectoryMode=0700
ReadWritePaths=${STATE} /run/maya-failover

[Install]
WantedBy=multi-user.target
EOF

systemctl stop "$SERVICE" 2>/dev/null || true
systemctl daemon-reload

echo
echo "=== FULL VLESS DIAGNOSTICS ==="
set +e
"$OPT/controller.py" --diagnose
DIAG_RC=$?
set -e
if [[ $DIAG_RC -ne 0 ]]; then
  echo "Diagnostics found an unexpected production DNS IP. Service was NOT started." >&2
  exit "$DIAG_RC"
fi

systemctl enable --now "$SERVICE" >/dev/null
sleep 2
systemctl is-active --quiet "$SERVICE" || {
  journalctl -u "$SERVICE" -n 100 --no-pager
  exit 1
}

echo
echo "OK: Maya monitor upgraded to full VLESS+Reality end-to-end health checks."
echo "Policy: every 15 seconds; 3 consecutive active-path failures; symmetric MAIN <-> SPARE switch."
echo "Old ping/TCP/TLS/WSS health policy and isolated test-record config were removed."
echo "VLESS credentials are local-only in $ETC/vless.env (0600), not stored in GitHub."
echo
echo "Check:"
echo "  maya-failover diagnose"
echo "  maya-failover status"
echo "  journalctl -u maya-failover -n 80 --no-pager"

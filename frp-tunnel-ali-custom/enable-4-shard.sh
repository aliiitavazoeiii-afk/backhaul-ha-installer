#!/usr/bin/env bash
set -Eeuo pipefail

APP="frp-tunnel-ali"
ETC="/etc/${APP}"
STATE="/var/lib/${APP}"
OPT="/opt/${APP}"
BIN="${OPT}/bin"
FRPC="${BIN}/frpc"
MAIN_SERVICE="${APP}.service"
SHARD_SERVICE="${APP}-shard@.service"
GROUP_KEY_FILE="${ETC}/load-balancer.key"
REFRESH_SCRIPT="/usr/local/sbin/${APP}-refresh-next-shard"
REFRESH_SERVICE="${APP}-refresh.service"
REFRESH_TIMER="${APP}-refresh.timer"
LOCK_FILE="/run/${APP}-4shard.lock"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "flock is required (util-linux)." >&2; exit 1; }
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another four-shard conversion is already running." >&2; exit 1; }

[[ -r "$ETC/meta.env" ]] || { echo "Missing $ETC/meta.env; install the validated FRP tunnel first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ETC/meta.env"
ROLE="${ROLE,,}"
[[ "$ROLE" == "foreign" ]] || { echo "This conversion runs only on the FOREIGN node." >&2; exit 1; }
[[ -x "$FRPC" ]] || { echo "Missing FRP client binary: $FRPC" >&2; exit 1; }
[[ -r "$ETC/frpc.toml" ]] || { echo "Missing $ETC/frpc.toml" >&2; exit 1; }
systemctl is-active --quiet "$MAIN_SERVICE" || { echo "$MAIN_SERVICE must be healthy/running before conversion." >&2; exit 1; }

PROFILE="${PROFILE:-normal}"
GROUP="ali-vpn-${PROFILE}-lb"
POOL_PER_SHARD=6
BASE_CFG="$(mktemp)"
TMP_DIR="$(mktemp -d)"
trap 'rm -f "$BASE_CFG"; rm -rf "$TMP_DIR"' EXIT
cp -a "$ETC/frpc.toml" "$BASE_CFG"

CLIENT_BASE="$(sed -n 's/^clientID = "\([^"]*\)".*/\1/p' "$BASE_CFG" | head -n1)"
PROXY_BASE="$(sed -n 's/^name = "\([^"]*\)".*/\1/p' "$BASE_CFG" | tail -n1)"
[[ -n "$CLIENT_BASE" ]] || CLIENT_BASE="ali-${PROFILE}"
[[ -n "$PROXY_BASE" ]] || PROXY_BASE="ali-vpn-${PROFILE}"

mkdir -p "$ETC" "$STATE/backups"
chmod 0700 "$ETC" "$STATE" "$STATE/backups"
if [[ ! -s "$GROUP_KEY_FILE" ]]; then
  openssl rand -hex 32 >"$GROUP_KEY_FILE"
  chmod 0600 "$GROUP_KEY_FILE"
fi
GROUP_KEY="$(tr -d '\r\n' <"$GROUP_KEY_FILE")"
[[ "$GROUP_KEY" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid load-balancer key file." >&2; exit 1; }

ts="$(date +%Y%m%d-%H%M%S)"
tar -C / -czf "$STATE/backups/pre-4shard-${ts}.tar.gz" "${ETC#/}" "etc/systemd/system/${MAIN_SERVICE}" 2>/dev/null || \
  tar -C / -czf "$STATE/backups/pre-4shard-${ts}.tar.gz" "${ETC#/}"
chmod 0600 "$STATE/backups/pre-4shard-${ts}.tar.gz"

echo "Backup: $STATE/backups/pre-4shard-${ts}.tar.gz"

make_cfg() {
  local idx="$1" out="$2" client proxy webport
  if [[ "$idx" == "01" ]]; then
    client="$CLIENT_BASE"
    proxy="$PROXY_BASE"
    webport=7400
  else
    client="${CLIENT_BASE}-s${idx}"
    proxy="${PROXY_BASE}-s${idx}"
    webport=$((7400 + 10#$idx - 1))
  fi

  awk \
    -v client="$client" \
    -v proxy="$proxy" \
    -v pool="$POOL_PER_SHARD" \
    -v group="$GROUP" \
    -v gkey="$GROUP_KEY" \
    -v webport="$webport" '
      BEGIN { in_proxy=0 }
      /^clientID[[:space:]]*=/ { print "clientID = \"" client "\""; next }
      /^transport\.poolCount[[:space:]]*=/ { print "transport.poolCount = " pool; next }
      /^webServer\.port[[:space:]]*=/ { print "webServer.port = " webport; next }
      /^loadBalancer\.(group|groupKey)[[:space:]]*=/ { next }
      /^\[\[proxies\]\]/ { in_proxy=1; print; next }
      in_proxy && /^name[[:space:]]*=/ { print "name = \"" proxy "\""; next }
      in_proxy && /^remotePort[[:space:]]*=/ {
        print
        print "loadBalancer.group = \"" group "\""
        print "loadBalancer.groupKey = \"" gkey "\""
        next
      }
      { print }
    ' "$BASE_CFG" >"$out"

  chmod 0600 "$out"
  "$FRPC" verify -c "$out" >/dev/null
}

for idx in 01 02 03 04; do
  make_cfg "$idx" "$TMP_DIR/frpc-shard-${idx}.toml"
done

cat >"/etc/systemd/system/$SHARD_SERVICE" <<EOF
[Unit]
Description=FRP Tunnel Ali four-shard worker %i
After=network-online.target ${MAIN_SERVICE}
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=${FRPC} verify -c ${ETC}/frpc-shard-%i.toml
ExecStart=${FRPC} -c ${ETC}/frpc-shard-%i.toml
Restart=always
RestartSec=2
TimeoutStopSec=20
KillSignal=SIGTERM
LimitNOFILE=1048576
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

# First put the already-running primary frpc into the load-balancer group.
# This is the only point where an existing single-frpc deployment can see a brief reconnect.
install -m 0600 "$TMP_DIR/frpc-shard-01.toml" "$ETC/frpc.toml"
for idx in 02 03 04; do
  install -m 0600 "$TMP_DIR/frpc-shard-${idx}.toml" "$ETC/frpc-shard-${idx}.toml"
done

systemctl daemon-reload
systemctl restart "$MAIN_SERVICE"
for _ in $(seq 1 20); do
  systemctl is-active --quiet "$MAIN_SERVICE" && break
  sleep 1
done
systemctl is-active --quiet "$MAIN_SERVICE" || { journalctl -u "$MAIN_SERVICE" -n 80 --no-pager; exit 1; }

for idx in 02 03 04; do
  systemctl enable --now "${APP}-shard@${idx}.service" >/dev/null
  for _ in $(seq 1 20); do
    systemctl is-active --quiet "${APP}-shard@${idx}.service" && break
    sleep 1
  done
  systemctl is-active --quiet "${APP}-shard@${idx}.service" || {
    journalctl -u "${APP}-shard@${idx}.service" -n 80 --no-pager
    exit 1
  }
done

cat >"$REFRESH_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP="frp-tunnel-ali"
STATE="/var/lib/${APP}"
IDX_FILE="$STATE/shard-refresh.idx"
LOCK="/run/${APP}-refresh.lock"
mkdir -p "$STATE"
exec 9>"$LOCK"
flock -n 9 || exit 0
units=(
  "${APP}-shard@02.service"
  "${APP}-shard@03.service"
  "${APP}-shard@04.service"
  "${APP}.service"
)
idx=0
if [[ -r "$IDX_FILE" ]]; then
  read -r idx <"$IDX_FILE" || idx=0
fi
[[ "$idx" =~ ^[0-3]$ ]] || idx=0
unit="${units[$idx]}"
logger -t frp-shard-refresh "refreshing $unit"
systemctl restart "$unit"
for _ in $(seq 1 20); do
  systemctl is-active --quiet "$unit" && break
  sleep 1
done
systemctl is-active --quiet "$unit"
next=$(( (idx + 1) % 4 ))
printf '%s\n' "$next" >"$IDX_FILE"
EOF
chmod 0755 "$REFRESH_SCRIPT"

cat >"/etc/systemd/system/$REFRESH_SERVICE" <<EOF
[Unit]
Description=Refresh one FRP shard without resetting the whole tunnel
After=network-online.target

[Service]
Type=oneshot
ExecStart=${REFRESH_SCRIPT}
EOF

cat >"/etc/systemd/system/$REFRESH_TIMER" <<'EOF'
[Unit]
Description=Staggered FRP shard connection refresh

[Timer]
OnBootSec=75min
OnUnitActiveSec=75min
RandomizedDelaySec=5min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "$REFRESH_TIMER" >/dev/null

# Give all four clients a moment to register their grouped TCP proxies.
sleep 3

failed=0
for unit in "$MAIN_SERVICE" \
  "${APP}-shard@02.service" \
  "${APP}-shard@03.service" \
  "${APP}-shard@04.service"; do
  if systemctl is-active --quiet "$unit"; then
    printf 'OK   %s\n' "$unit"
  else
    printf 'FAIL %s\n' "$unit"
    failed=1
  fi
done

if [[ -n "${DOMAIN:-}" && -n "${PUBLIC_PORT:-}" ]]; then
  if timeout 5 bash -c "</dev/tcp/${DOMAIN}/${PUBLIC_PORT}" 2>/dev/null; then
    echo "OK   end-to-end ${DOMAIN}:${PUBLIC_PORT}"
  else
    echo "FAIL end-to-end ${DOMAIN}:${PUBLIC_PORT}"
    failed=1
  fi
fi

echo
echo "Four-shard layout enabled: 4 x pool ${POOL_PER_SHARD}, tcpMux remains disabled."
echo "Each shard is refreshed once per ~5 hours; only one shard is restarted per ~75 minutes."
echo "Timer: systemctl list-timers ${REFRESH_TIMER}"
echo "Services: ${MAIN_SERVICE}, ${APP}-shard@02.service, @03.service, @04.service"
echo "Load-balancer group: ${GROUP}"

((failed==0)) || exit 1

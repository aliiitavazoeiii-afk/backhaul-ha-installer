#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="aliiitavazoeiii-afk/backhaul-ha-installer"
ENGINE_REF="a1449de47fe13a20aacfe22e56412a4e50f9854a"
GO_VERSION="1.27.0"
GO_SHA256_AMD64="675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685"
DEFAULT_FOREIGN_IP="31.57.26.176"
CARRIER_PORT="443"
USER_TEST_PORT="24443"
INSTALL_DIR="/opt/aegis-t"
BIN="/usr/local/bin/aegis-t"
SERVER_SERVICE="/etc/systemd/system/aegis-t-server.service"

log(){ printf '\033[1;36m[Aegis-T]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."; }
cleanup(){ rm -rf /tmp/aegis-t-src.* /tmp/go.tar.gz 2>/dev/null || true; }
trap cleanup EXIT

need_root
[[ -r /etc/os-release ]] || die "Unsupported OS."
. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) die "Only Ubuntu/Debian are supported for this canary." ;; esac
[[ $(uname -m) == "x86_64" ]] || die "This canary installer currently supports amd64/x86_64 only."

IRAN_IP="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
[[ $IRAN_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not detect Iran public IPv4."

printf 'Carrier domain (DNS A must point to %s): ' "$IRAN_IP"
read -r DOMAIN
[[ $DOMAIN =~ ^[A-Za-z0-9.-]+$ && $DOMAIN == *.* ]] || die "Invalid domain."

printf 'Foreign IPv4 [%s]: ' "$DEFAULT_FOREIGN_IP"
read -r FOREIGN_IP
FOREIGN_IP="${FOREIGN_IP:-$DEFAULT_FOREIGN_IP}"
[[ $FOREIGN_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid foreign IPv4."

log "Iran=$IRAN_IP Foreign=$FOREIGN_IP Domain=$DOMAIN"
log "Canary data path: user -> $IRAN_IP:$USER_TEST_PORT -> dedicated TLS/TCP carrier -> $FOREIGN_IP -> 127.0.0.1:443"
printf 'Continue? [y/N]: '
read -r ans
[[ $ans == y || $ans == Y ]] || exit 0

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl tar openssh-client certbot jq openssl

# Refuse destructive port takeover. This canary intentionally binds carrier TLS directly to :443.
if ss -H -lnt "sport = :$CARRIER_PORT" 2>/dev/null | grep -q .; then
  echo
  ss -lntp "sport = :$CARRIER_PORT" || true
  die "TCP :$CARRIER_PORT is already in use on Iran. Canary installer made no service changes."
fi
if ss -H -lnt "sport = :$USER_TEST_PORT" 2>/dev/null | grep -q .; then
  echo
  ss -lntp "sport = :$USER_TEST_PORT" || true
  die "TCP :$USER_TEST_PORT is already in use on Iran."
fi

DNS_A="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u | tr '\n' ' ')"
[[ " $DNS_A " == *" $IRAN_IP "* ]] || die "DNS A for $DOMAIN does not include $IRAN_IP (got: ${DNS_A:-none})."

# Set up SSH key without storing a password. If key auth is not ready, ssh-copy-id prompts locally.
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [[ ! -f /root/.ssh/id_ed25519 ]]; then
  ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
fi
SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new)
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$FOREIGN_IP" true 2>/dev/null; then
  log "SSH key auth is not ready. ssh-copy-id will ask for the foreign root password in this terminal only."
  ssh-copy-id "${SSH_OPTS[@]}" -i /root/.ssh/id_ed25519.pub "root@$FOREIGN_IP"
fi
ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$FOREIGN_IP" true || die "SSH key authentication failed."

REMOTE_ARCH="$(ssh "${SSH_OPTS[@]}" root@"$FOREIGN_IP" 'uname -m')"
[[ $REMOTE_ARCH == x86_64 ]] || die "Foreign architecture is $REMOTE_ARCH; this canary supports x86_64 only."

# Verify the user-managed Xray target. We do not install, edit, restart, or sync 3x-ui/Xray.
ssh "${SSH_OPTS[@]}" root@"$FOREIGN_IP" "timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443'" \
  || die "Foreign 127.0.0.1:443 is not reachable. Configure your Xray inbound first."

# Obtain a real certificate. Port 80 must be available for the one-time HTTP-01 challenge.
if [[ ! -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" || ! -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
  if ss -H -lnt 'sport = :80' 2>/dev/null | grep -q .; then
    ss -lntp 'sport = :80' || true
    die "TCP :80 is in use and no existing certificate was found for $DOMAIN. Free :80, then rerun."
  fi
  certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$DOMAIN"
fi
[[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]] \
  || die "Certificate files missing after certbot."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/aegis-t-restart.sh <<'HOOK'
#!/usr/bin/env bash
systemctl try-restart aegis-t-server.service >/dev/null 2>&1 || true
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/aegis-t-restart.sh

# Install a pinned Go toolchain only when needed. Official checksum from go.dev.
GO_OK=0
if command -v go >/dev/null 2>&1; then
  if go version | grep -Eq 'go1\.(2[3-9]|[3-9][0-9])'; then GO_OK=1; fi
fi
if [[ $GO_OK -ne 1 ]]; then
  log "Installing pinned Go $GO_VERSION build toolchain."
  curl -fL --retry 4 --retry-delay 2 -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  echo "$GO_SHA256_AMD64  /tmp/go.tar.gz" | sha256sum -c -
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  export PATH="/usr/local/go/bin:$PATH"
fi

TMP="$(mktemp -d /tmp/aegis-t-src.XXXXXX)"
log "Fetching immutable engine commit $ENGINE_REF"
curl -fL --retry 4 --retry-delay 2 \
  -o "$TMP/src.tar.gz" \
  "https://github.com/$REPO/archive/$ENGINE_REF.tar.gz"
tar -xzf "$TMP/src.tar.gz" -C "$TMP"
SRC_ROOT="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -d "$SRC_ROOT/aegis-t" ]] || die "Aegis-T source directory missing."
(
  cd "$SRC_ROOT/aegis-t"
  go test ./... -count=1 -timeout=60s
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$TMP/aegis-t" ./cmd/aegis-t
)
[[ "$($TMP/aegis-t -version)" == "1.0.0" ]] || die "Built binary version check failed."
install -m 0755 "$TMP/aegis-t" "$BIN"

mkdir -p "$INSTALL_DIR"
TOKEN="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '\n')"
PATH_PREFIX="/assets/$(openssl rand -hex 12 2>/dev/null || date +%s%N)"

cat >"$INSTALL_DIR/server.json" <<JSON
{
  "carrier_listen": "0.0.0.0:$CARRIER_PORT",
  "user_listen": "0.0.0.0:$USER_TEST_PORT",
  "readiness_listen": "127.0.0.1:10444",
  "cert_file": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
  "key_file": "/etc/letsencrypt/live/$DOMAIN/privkey.pem",
  "token": "$TOKEN",
  "path_prefix": "$PATH_PREFIX",
  "host": "$DOMAIN",
  "min_ready": 4,
  "max_idle": 128,
  "acquire_timeout_ms": 2000,
  "carrier_ttl_seconds": 180
}
JSON
chmod 600 "$INSTALL_DIR/server.json"

cat >"$INSTALL_DIR/client.json" <<JSON
{
  "remote_addr": "$IRAN_IP:$CARRIER_PORT",
  "edge_ip": "$IRAN_IP",
  "tls_server_name": "$DOMAIN",
  "token": "$TOKEN",
  "path_prefix": "$PATH_PREFIX",
  "pool": 32,
  "target": "127.0.0.1:443",
  "health_target": "127.0.0.1:443",
  "health_interval_seconds": 2,
  "dial_timeout_seconds": 8,
  "padding_min": 96,
  "padding_max": 640
}
JSON
chmod 600 "$INSTALL_DIR/client.json"

cat >"$SERVER_SERVICE" <<'UNIT'
[Unit]
Description=Aegis-T dedicated-carrier server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/aegis-t -role server -config /opt/aegis-t/server.json
Restart=always
RestartSec=2
LimitNOFILE=262144
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/aegis-t

[Install]
WantedBy=multi-user.target
UNIT

# Ship only the binary and client config; never touch 3x-ui/Xray.
scp "${SSH_OPTS[@]}" "$BIN" root@"$FOREIGN_IP":/usr/local/bin/aegis-t
scp "${SSH_OPTS[@]}" "$INSTALL_DIR/client.json" root@"$FOREIGN_IP":/tmp/aegis-t-client.json
ssh "${SSH_OPTS[@]}" root@"$FOREIGN_IP" 'bash -s' <<'REMOTE'
set -Eeuo pipefail
mkdir -p /opt/aegis-t
install -m 0600 /tmp/aegis-t-client.json /opt/aegis-t/client.json
rm -f /tmp/aegis-t-client.json
cat >/etc/systemd/system/aegis-t-client.service <<'UNIT'
[Unit]
Description=Aegis-T dedicated-carrier client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/aegis-t -role client -config /opt/aegis-t/client.json
Restart=always
RestartSec=2
LimitNOFILE=262144
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/aegis-t

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable aegis-t-client.service >/dev/null
REMOTE

systemctl daemon-reload
systemctl enable aegis-t-server.service >/dev/null
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow ${CARRIER_PORT}/tcp >/dev/null
  ufw allow ${USER_TEST_PORT}/tcp >/dev/null
fi

systemctl restart aegis-t-server.service
sleep 1
ssh "${SSH_OPTS[@]}" root@"$FOREIGN_IP" 'systemctl restart aegis-t-client.service'

log "Waiting for warm carrier pool/readiness."
READY=0
for _ in $(seq 1 30); do
  if timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/10444' 2>/dev/null; then READY=1; break; fi
  sleep 1
done
if [[ $READY -ne 1 ]]; then
  echo "=== Iran server log ==="
  journalctl -u aegis-t-server -n 60 --no-pager || true
  echo "=== Foreign client log ==="
  ssh "${SSH_OPTS[@]}" root@"$FOREIGN_IP" 'journalctl -u aegis-t-client -n 60 --no-pager' || true
  die "Readiness did not come UP. Services were left installed for diagnostics."
fi

cat > /usr/local/sbin/aegis-t-status <<EOF2
#!/usr/bin/env bash
set -u
echo '=== IRAN ==='
systemctl is-active aegis-t-server || true
ss -lntp | grep -E ':${CARRIER_PORT}|:${USER_TEST_PORT}|:10444' || true
echo '=== FOREIGN ==='
ssh ${SSH_OPTS[*]} root@${FOREIGN_IP} 'systemctl is-active aegis-t-client; ss -tn dst ${IRAN_IP}:${CARRIER_PORT} | head -40' || true
EOF2
chmod 0755 /usr/local/sbin/aegis-t-status

cat > /usr/local/sbin/aegis-t-uninstall-canary <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl disable --now aegis-t-server.service 2>/dev/null || true
rm -f /etc/systemd/system/aegis-t-server.service
systemctl daemon-reload
ssh ${SSH_OPTS[*]} root@${FOREIGN_IP} 'systemctl disable --now aegis-t-client.service 2>/dev/null || true; rm -f /etc/systemd/system/aegis-t-client.service /opt/aegis-t/client.json /usr/local/bin/aegis-t; systemctl daemon-reload'
rm -f /usr/local/bin/aegis-t /usr/local/sbin/aegis-t-status /usr/local/sbin/aegis-t-uninstall-canary
rm -rf /opt/aegis-t
EOF2
chmod 0755 /usr/local/sbin/aegis-t-uninstall-canary

log "CANARY READY"
echo "Iran carrier TLS :$CARRIER_PORT"
echo "Iran user test port :$USER_TEST_PORT"
echo "Foreign target      127.0.0.1:443"
echo "Status command      aegis-t-status"
echo "Uninstall command   aegis-t-uninstall-canary"
echo
echo "Next: create ONE test VPN config using Iran IP $IRAN_IP and port $USER_TEST_PORT, then test before moving any users."

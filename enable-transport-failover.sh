#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
BUNDLE="/root/backhaul-ha-secrets.env"
RAW_BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/main"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || { echo "Tunnel role not found" >&2; exit 2; }
[[ -f "$BUNDLE" ]] || { echo "Missing $BUNDLE" >&2; exit 2; }

bundle_get() {
  sed -n "s/^${1}='\([^']*\)'$/\1/p" "$BUNDLE" | head -n1
}

bundle_set() {
  local key="$1" value="$2"
  if grep -q "^${key}='" "$BUNDLE"; then
    sed -i "s|^${key}='[^']*'$|${key}='${value}'|" "$BUNDLE"
  else
    printf "%s='%s'\n" "$key" "$value" >> "$BUNDLE"
  fi
  chmod 0600 "$BUNDLE"
}

valid_token() { [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]; }

IRAN_IP="$(bundle_get IRAN_IP)"
FOREIGN_IP="$(bundle_get FOREIGN_IP)"
TOKEN="$(bundle_get TCP_PLAIN_TOKEN)"

if [[ "$ROLE" == "iran" ]]; then
  if ! valid_token "$TOKEN"; then
    TOKEN="$(openssl rand -hex 32)"
    bundle_set TCP_PLAIN_TOKEN "$TOKEN"
  fi

  install -d -m 0700 /etc/backhaul
  cat > /etc/backhaul/server-tcp.toml <<CFG
[server]
bind_addr = "0.0.0.0:3081"
transport = "tcp"
token = "$TOKEN"
accept_udp = false
keepalive_period = 75
heartbeat = 40
nodelay = true
channel_size = 2048
sniffer = false
web_port = 0
log_level = "debug"

ports = [
    "12443=127.0.0.1:443",
    "12444=127.0.0.1:18090",
    "12445=127.0.0.1:5201"
]
CFG
  chmod 0600 /etc/backhaul/server-tcp.toml

  cat > /etc/systemd/system/backhaul-tcp.service <<'UNIT'
[Unit]
Description=Backhaul Plain TCP Server (third failover path)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/server-tcp.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  if command -v ufw >/dev/null 2>&1; then
    ufw allow from "$FOREIGN_IP" to any port 3081 proto tcp comment 'Backhaul plain TCP control' >/dev/null
  fi

  if [[ -f /etc/haproxy/haproxy.cfg ]]; then
    cp -a /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.pre-plain-tcp
    if ! grep -q 'tcp_plain_backup' /etc/haproxy/haproxy.cfg; then
      sed -i '/server tcp_backup .*backup/a\    server tcp_plain_backup 127.0.0.1:12443 check port 12444 inter 2s fall 2 rise 2 backup' /etc/haproxy/haproxy.cfg
    fi
    if ! haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
      cp -a /etc/haproxy/haproxy.cfg.pre-plain-tcp /etc/haproxy/haproxy.cfg
      echo "HAProxy validation failed; restored previous config" >&2
      exit 3
    fi
  fi

  systemctl daemon-reload
  systemctl enable --now backhaul-tcp >/dev/null
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
  echo "Third transport ready on Iran: plain TCP control :3081, data :12443, health :12444."
else
  valid_token "$TOKEN" || { echo "TCP_PLAIN_TOKEN missing from bundle. Run the updated Iran installer first, then copy the bundle again." >&2; exit 2; }

  install -d -m 0700 /etc/backhaul
  cat > /etc/backhaul/client-tcp.toml <<CFG
[client]
remote_addr = "$IRAN_IP:3081"
transport = "tcp"
token = "$TOKEN"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true
sniffer = false
web_port = 0
log_level = "debug"
CFG
  chmod 0600 /etc/backhaul/client-tcp.toml

  cat > /etc/systemd/system/backhaul-tcp.service <<'UNIT'
[Unit]
Description=Backhaul Plain TCP Client (third failover path)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/client-tcp.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now backhaul-tcp >/dev/null
  echo "Third transport ready on Foreign: plain TCP -> Iran :3081."
fi

curl -fsSL "$RAW_BASE/tunnelctl3.sh" -o /usr/local/bin/tunnelctl
chmod 0755 /usr/local/bin/tunnelctl

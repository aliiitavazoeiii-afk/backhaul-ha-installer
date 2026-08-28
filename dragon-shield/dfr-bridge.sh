#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

TABLE="dragon_shield_dfr"
CONF="/etc/dragon-shield/dfr-bridge.conf"
UNIT="/etc/systemd/system/dragon-shield-dfr-bridge.service"
RULES="/etc/dragon-shield/dfr-bridge.nft"

log(){ printf '[dfr-bridge] %s\n' "$*"; }
die(){ printf '[dfr-bridge] ERROR: %s\n' "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'run as root'; }

usage(){
  cat <<'USAGE'
Usage:
  dfr-bridge.sh install --public-ip <egress-public-ip> --shield-ip <overlay-server-ip> --udp-port <dfr-port>
  dfr-bridge.sh remove
  dfr-bridge.sh status

Example:
  dfr-bridge.sh install --public-ip 31.57.26.122 --shield-ip 10.203.0.1 --udp-port 45001
USAGE
}

write_rules(){
  # shellcheck disable=SC1090
  source "$CONF"
  cat >"$RULES" <<NFT
table inet ${TABLE} {
  chain output {
    type nat hook output priority dstnat; policy accept;
    ip daddr ${PUBLIC_IP} udp dport ${UDP_PORT} dnat ip to ${SHIELD_IP}:${UDP_PORT}
  }
}
NFT
}

apply(){
  [[ -r "$CONF" ]] || die "missing $CONF"
  command -v nft >/dev/null 2>&1 || die 'nft command missing'
  write_rules
  # First install has no table yet. Delete an old table if present, then load
  # the complete replacement atomically from the generated rules file.
  nft delete table inet "$TABLE" >/dev/null 2>&1 || true
  nft -f "$RULES"
}

install_bridge(){
  local public_ip="" shield_ip="" udp_port=""
  while (($#)); do
    case "$1" in
      --public-ip) public_ip="${2:-}"; shift 2 ;;
      --shield-ip) shield_ip="${2:-}"; shift 2 ;;
      --udp-port) udp_port="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'invalid --public-ip'
  [[ "$shield_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'invalid --shield-ip'
  [[ "$udp_port" =~ ^[0-9]+$ ]] && ((udp_port>=1 && udp_port<=65535)) || die 'invalid --udp-port'
  ip link show dfrshield0 >/dev/null 2>&1 || die 'dfrshield0 is not present; bring Dragon Shield up first'

  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nftables >/dev/null
  install -d -m 0700 /etc/dragon-shield
  cat >"$CONF" <<EOF
PUBLIC_IP=${public_ip}
SHIELD_IP=${shield_ip}
UDP_PORT=${udp_port}
EOF
  chmod 0600 "$CONF"

  cat >"$UNIT" <<'UNITFILE'
[Unit]
Description=Dragon Shield DFR public endpoint bridge
After=network-online.target dragon-shield.service
Wants=network-online.target dragon-shield.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dragon-shield-dfr-bridge apply
RemainAfterExit=yes
ExecStop=-/usr/sbin/nft delete table inet dragon_shield_dfr

[Install]
WantedBy=multi-user.target
UNITFILE
  install -m 0755 "$0" /usr/local/sbin/dragon-shield-dfr-bridge
  systemctl daemon-reload
  systemctl enable dragon-shield-dfr-bridge.service >/dev/null
  systemctl restart dragon-shield-dfr-bridge.service
  log "bridging UDP ${udp_port} for ${public_ip} through ${shield_ip}"
}

remove_bridge(){
  systemctl disable --now dragon-shield-dfr-bridge.service >/dev/null 2>&1 || true
  nft delete table inet "$TABLE" >/dev/null 2>&1 || true
  rm -f "$UNIT" "$RULES" "$CONF" /usr/local/sbin/dragon-shield-dfr-bridge
  systemctl daemon-reload
  log 'removed'
}

status_bridge(){
  echo '=== Dragon Shield ==='
  ip -br addr show dfrshield0 2>/dev/null || true
  echo '=== DFR bridge config ==='
  if [[ -r "$CONF" ]]; then cat "$CONF"; else echo 'not configured'; fi
  echo '=== nft ==='
  nft list table inet "$TABLE" 2>/dev/null || echo 'rule not active'
}

need_root
case "${1:-}" in
  install) shift; install_bridge "$@" ;;
  apply) apply ;;
  remove) remove_bridge ;;
  status) status_bridge ;;
  *) usage; exit 2 ;;
esac

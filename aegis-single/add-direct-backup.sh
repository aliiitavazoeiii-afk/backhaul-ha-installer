#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=''
IRAN_IP=''
BACKUP_IP=''
HAPROXY_CFG='/etc/haproxy/haproxy.cfg'
STATE_DIR='/etc/aegis-direct-backup'

log(){ printf '[+] %s\n' "$*"; }
info(){ printf '[i] %s\n' "$*"; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

usage(){
  cat <<'EOF'
Usage:
  Foreign backup:
    add-direct-backup.sh --role foreign --iran-ip 185.215.230.207 --backup-ip 193.57.9.55

  Iran gateway:
    add-direct-backup.sh --role iran --iran-ip 185.215.230.207 --backup-ip 193.57.9.55
EOF
}

valid_ipv4(){
  local ip="$1" IFS=. a b c d x
  read -r a b c d <<<"$ip" || return 1
  [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for x in "$a" "$b" "$c" "$d"; do
    [[ "$x" =~ ^[0-9]+$ ]] || return 1
    (( x >= 0 && x <= 255 )) || return 1
  done
}

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run as root.'; }

parse_args(){
  while (($#)); do
    case "$1" in
      --role) ROLE="${2:-}"; shift 2 ;;
      --iran-ip) IRAN_IP="${2:-}"; shift 2 ;;
      --backup-ip) BACKUP_IP="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
  [[ "$ROLE" == 'foreign' || "$ROLE" == 'iran' ]] || die '--role must be foreign or iran.'
  valid_ipv4 "$IRAN_IP" || die 'Invalid Iran IPv4.'
  valid_ipv4 "$BACKUP_IP" || die 'Invalid backup IPv4.'
}

xray_local_up(){
  timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' >/dev/null 2>&1
}

public_443_line(){
  ss -Hlnpt '( sport = :443 )' 2>/dev/null | awk '$4 != "127.0.0.1:443" && $4 != "[::1]:443" {print; exit}'
}

find_socket_proxyd(){
  local p
  p="$(command -v systemd-socket-proxyd 2>/dev/null || true)"
  if [[ -z "$p" ]]; then
    for p in /usr/lib/systemd/systemd-socket-proxyd /lib/systemd/systemd-socket-proxyd; do
      [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    return 1
  fi
  printf '%s' "$p"
}

install_foreign_relay(){
  need_root
  command -v systemctl >/dev/null || die 'systemd is required.'
  command -v ss >/dev/null || die 'ss is required.'

  xray_local_up || die 'Nothing healthy is accepting TCP on 127.0.0.1:443. Keep Xray local inbound there first.'

  local existing proxyd
  existing="$(public_443_line || true)"
  if [[ -n "$existing" ]]; then
    if grep -Eqi 'users:\(\("xray"|xray' <<<"$existing"; then
      log "Xray already owns a public :443 listener; no relay is required."
      info "$existing"
      return 0
    fi
    die "Public :443 is already owned by another service; refusing to replace it: $existing"
  fi

  proxyd="$(find_socket_proxyd)" || die 'systemd-socket-proxyd was not found.'
  install -d -m 0755 "$STATE_DIR"

  cat > /usr/local/sbin/aegis-backup-watchdog <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' >/dev/null 2>&1; then
  if ! systemctl is-active --quiet aegis-direct-backup.socket; then
    systemctl start aegis-direct-backup.socket
  fi
else
  systemctl stop aegis-direct-backup.service aegis-direct-backup.socket >/dev/null 2>&1 || true
fi
EOF
  chmod 0755 /usr/local/sbin/aegis-backup-watchdog

  cat > /etc/systemd/system/aegis-direct-backup.socket <<EOF
[Unit]
Description=Aegis direct backup public TCP socket

[Socket]
ListenStream=${BACKUP_IP}:443
NoDelay=true
KeepAlive=true
Backlog=4096

[Install]
WantedBy=sockets.target
EOF

  cat > /etc/systemd/system/aegis-direct-backup.service <<EOF
[Unit]
Description=Aegis direct backup TCP relay to local Xray
Requires=aegis-direct-backup.socket
After=network-online.target

[Service]
ExecStart=${proxyd} 127.0.0.1:443
PrivateTmp=true
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
EOF

  cat > /etc/systemd/system/aegis-backup-watchdog.service <<'EOF'
[Unit]
Description=Health gate for Aegis direct backup relay

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/aegis-backup-watchdog
EOF

  cat > /etc/systemd/system/aegis-backup-watchdog.timer <<'EOF'
[Unit]
Description=Run Aegis backup health gate every two seconds

[Timer]
OnBootSec=1s
OnUnitActiveSec=2s
AccuracySec=500ms
Unit=aegis-backup-watchdog.service

[Install]
WantedBy=timers.target
EOF

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow from "$IRAN_IP" to any port 443 proto tcp >/dev/null || true
  fi

  systemctl daemon-reload
  systemctl disable --now aegis-direct-backup.socket >/dev/null 2>&1 || true
  systemctl enable --now aegis-backup-watchdog.timer >/dev/null
  systemctl start aegis-backup-watchdog.service
  sleep 1

  xray_local_up || die 'Xray local health was lost during backup setup.'
  ss -Hlnpt '( sport = :443 )' 2>/dev/null | grep -Fq "${BACKUP_IP}:443" || die "Backup relay did not bind ${BACKUP_IP}:443."

  log "FOREIGN backup ready: ${BACKUP_IP}:443 -> 127.0.0.1:443"
  log "Only the Iran gateway should use this path in normal operation."
}

iran_can_reach_backup(){
  timeout 4 bash -c "exec 3<>/dev/tcp/${BACKUP_IP}/443" >/dev/null 2>&1
}

install_iran_backup(){
  need_root
  command -v haproxy >/dev/null || die 'HAProxy is not installed on Iran.'
  [[ -s "$HAPROXY_CFG" ]] || die 'HAProxy config not found.'
  grep -q '^backend user_gateway$' "$HAPROXY_CFG" || die 'Aegis user_gateway backend not found.'
  grep -Eq '^[[:space:]]*server[[:space:]]+aegis_primary[[:space:]]+127\.0\.0\.1:10443([[:space:]]|$)' "$HAPROXY_CFG" || die 'Expected Aegis primary server line not found.'

  iran_can_reach_backup || die "Iran cannot connect to ${BACKUP_IP}:443. Do not modify failover until the standby is reachable."

  local backup tmp line
  backup="${HAPROXY_CFG}.pre-direct-backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$HAPROXY_CFG" "$backup"
  tmp="$(mktemp)"
  line="    server direct_backup ${BACKUP_IP}:443 check inter 2s fall 3 rise 3 backup on-marked-down shutdown-sessions"

  awk -v newline="$line" '
    /^[[:space:]]*server[[:space:]]+direct_backup[[:space:]]+/ { next }
    { print }
    /^[[:space:]]*server[[:space:]]+aegis_primary[[:space:]]+/ { print newline }
  ' "$HAPROXY_CFG" > "$tmp"

  cat "$tmp" > "$HAPROXY_CFG"
  rm -f "$tmp"

  if ! haproxy -c -f "$HAPROXY_CFG"; then
    cp -a "$backup" "$HAPROXY_CFG"
    die "HAProxy validation failed; restored $backup"
  fi

  systemctl reload haproxy
  sleep 2
  systemctl is-active --quiet haproxy || {
    cp -a "$backup" "$HAPROXY_CFG"
    systemctl restart haproxy || true
    die 'HAProxy did not remain active; previous config was restored.'
  }

  log "IRAN direct standby installed. Backup config: $backup"
  info 'Primary remains Aegis. direct_backup is marked backup and receives no normal traffic while Aegis is healthy.'
  grep -A8 '^backend user_gateway$' "$HAPROXY_CFG"
}

need_root
parse_args "$@"
case "$ROLE" in
  foreign) install_foreign_relay ;;
  iran) install_iran_backup ;;
esac

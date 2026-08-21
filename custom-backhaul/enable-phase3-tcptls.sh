#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE="/root/backhaul-ha-secrets.env"
PHASE2_MARKER="/etc/backhaul-ha/phase2-stealth-wss"
PHASE3_MARKER="/etc/backhaul-ha/phase3-tcptls"
BACKUP_PTR="/etc/backhaul-ha/phase3-backup-path"
STUNNEL_CONF="/etc/stunnel/backhaul-tcpmux.conf"
STUNNEL_UNIT="/etc/systemd/system/backhaul-tcptls.service"
BACKHAUL_DROPIN="/etc/systemd/system/backhaul.service.d/phase3-tcptls.conf"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/backhaul-phase3-tcptls"
SERVER_TLS_PORT=9444
SERVER_RAW_PORT=18081
CLIENT_LOCAL_PORT=13080
TCP_TLS_DOMAIN_ARG=""

usage() {
  cat <<'USAGE'
Usage:
  Iran:    enable-phase3-tcptls.sh --domain SECOND_SNI_DOMAIN
  Foreign: enable-phase3-tcptls.sh

The SECOND_SNI_DOMAIN must already resolve to the Iran public IP.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) TCP_TLS_DOMAIN_ARG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[x] Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[x] Run as root." >&2; exit 1; }
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == iran || "$ROLE" == foreign ]] || { echo "[x] Tunnel role not detected." >&2; exit 2; }
[[ -f "$BUNDLE" ]] || { echo "[x] Missing $BUNDLE" >&2; exit 2; }
[[ -f "$PHASE2_MARKER" ]] || { echo "[x] Phase 2 marker missing. Complete Phase 2 first." >&2; exit 3; }
[[ -x /usr/local/bin/backhaul ]] || { echo "[x] Backhaul binary missing." >&2; exit 3; }

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

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

set_toml_string() {
  local file="$1" key="$2" value="$3"
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*$|${key} = \"${value}\"|" "$file"
  else
    printf '\n%s = "%s"\n' "$key" "$value" >> "$file"
  fi
}

init_backup() {
  install -d -m 0755 /etc/backhaul-ha
  if [[ -f "$BACKUP_PTR" ]]; then
    BACKUP_ROOT="$(cat "$BACKUP_PTR")"
    [[ -d "$BACKUP_ROOT" ]] || { echo "[x] Saved Phase 3 backup directory is missing: $BACKUP_ROOT" >&2; exit 4; }
    return
  fi

  BACKUP_ROOT="/root/backhaul-ha-backups/phase3-$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$BACKUP_ROOT"
  : > "$BACKUP_ROOT/.missing"
  printf '%s\n' "$BACKUP_ROOT" > "$BACKUP_PTR"
  chmod 0600 "$BACKUP_PTR"
}

backup_path() {
  local p="$1"
  [[ -e "$BACKUP_ROOT$p" || -L "$BACKUP_ROOT$p" ]] && return 0
  if [[ -e "$p" || -L "$p" ]]; then
    mkdir -p "$BACKUP_ROOT$(dirname "$p")"
    cp -a -- "$p" "$BACKUP_ROOT$p"
  else
    printf '%s\n' "$p" >> "$BACKUP_ROOT/.missing"
  fi
}

tls_probe() {
  local host="$1" target_host="$2" target_port="$3"
  python3 - "$host" "$target_host" "$target_port" <<'PY'
import socket, ssl, sys
host, target, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
ctx = ssl.create_default_context()
with socket.create_connection((target, port), timeout=6) as raw:
    with ctx.wrap_socket(raw, server_hostname=host) as tls:
        if not tls.version():
            raise SystemExit(1)
PY
}

IRAN_IP="$(bundle_get IRAN_IP)"
FOREIGN_IP="$(bundle_get FOREIGN_IP)"
BACKBONE_DOMAIN="$(cat /etc/backhaul-ha/domain 2>/dev/null || true)"
[[ -n "$BACKBONE_DOMAIN" ]] || BACKBONE_DOMAIN="$(bundle_get DOMAIN)"
TCP_TLS_DOMAIN="$(bundle_get TCP_TLS_DOMAIN)"

if [[ -n "$TCP_TLS_DOMAIN_ARG" ]]; then
  valid_domain "$TCP_TLS_DOMAIN_ARG" || { echo "[x] Invalid --domain value." >&2; exit 2; }
  if [[ -n "$TCP_TLS_DOMAIN" && "$TCP_TLS_DOMAIN" != "$TCP_TLS_DOMAIN_ARG" ]]; then
    echo "[x] Bundle already contains TCP_TLS_DOMAIN=$TCP_TLS_DOMAIN; refusing an implicit rotation." >&2
    exit 2
  fi
  TCP_TLS_DOMAIN="$TCP_TLS_DOMAIN_ARG"
fi

if [[ "$ROLE" == iran ]]; then
  [[ -n "$TCP_TLS_DOMAIN" ]] || { echo "[x] Phase 3 needs a second TLS hostname. Re-run with --domain SECOND_SNI_DOMAIN." >&2; exit 5; }
  valid_domain "$TCP_TLS_DOMAIN" || { echo "[x] Invalid TCP_TLS_DOMAIN." >&2; exit 5; }
  [[ "$TCP_TLS_DOMAIN" != "$BACKBONE_DOMAIN" ]] || { echo "[x] Phase 3 TLS hostname must differ from the Phase 2 backbone hostname." >&2; exit 5; }
  [[ -f /etc/backhaul/server.toml ]] || { echo "[x] Missing /etc/backhaul/server.toml" >&2; exit 5; }
  [[ -f /etc/haproxy/haproxy.cfg ]] || { echo "[x] Missing HAProxy config." >&2; exit 5; }

  resolved="$(getent ahostsv4 "$TCP_TLS_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
  [[ "$resolved" == "$IRAN_IP" ]] || { echo "[x] $TCP_TLS_DOMAIN resolves to ${resolved:-none}; expected Iran IP $IRAN_IP" >&2; exit 5; }

  init_backup
  backup_path /etc/backhaul/server.toml
  backup_path /etc/haproxy/haproxy.cfg
  backup_path "$BUNDLE"
  backup_path "$STUNNEL_CONF"
  backup_path "$STUNNEL_UNIT"
  backup_path "$BACKHAUL_DROPIN"
  backup_path "$RENEW_HOOK"

  bundle_set TCP_TLS_DOMAIN "$TCP_TLS_DOMAIN"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y stunnel4 certbot python3 ca-certificates

  if [[ ! -f "/etc/letsencrypt/live/$TCP_TLS_DOMAIN/fullchain.pem" || ! -f "/etc/letsencrypt/live/$TCP_TLS_DOMAIN/privkey.pem" ]]; then
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)(80)$'; then
      echo "[x] TCP :80 is busy; cannot safely run Certbot standalone HTTP-01." >&2
      exit 6
    fi
    certbot certonly --standalone --preferred-challenges http \
      --non-interactive --agree-tos --register-unsafely-without-email \
      -d "$TCP_TLS_DOMAIN"
  fi

  install -d -m 0755 /etc/stunnel /etc/systemd/system/backhaul.service.d /etc/letsencrypt/renewal-hooks/deploy

  cat > "$STUNNEL_CONF" <<CFG
foreground = yes
syslog = no
debug = notice
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[backhaul-tcpmux]
accept = 127.0.0.1:${SERVER_TLS_PORT}
connect = 127.0.0.1:${SERVER_RAW_PORT}
cert = /etc/letsencrypt/live/${TCP_TLS_DOMAIN}/fullchain.pem
key = /etc/letsencrypt/live/${TCP_TLS_DOMAIN}/privkey.pem
sslVersionMin = TLSv1.2
TIMEOUTconnect = 10
TIMEOUTclose = 5
TIMEOUTidle = 43200
CFG
  chmod 0600 "$STUNNEL_CONF"

  cat > "$STUNNEL_UNIT" <<UNIT
[Unit]
Description=Phase 3 TLS wrapper for Backhaul TCPMux
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/stunnel ${STUNNEL_CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  cat > "$BACKHAUL_DROPIN" <<'UNIT'
[Unit]
After=backhaul-tcptls.service
Requires=backhaul-tcptls.service
UNIT

  cat > "$RENEW_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -eu
if systemctl is-enabled --quiet backhaul-tcptls.service 2>/dev/null; then
  systemctl restart backhaul-tcptls.service
fi
HOOK
  chmod 0755 "$RENEW_HOOK"

  set_toml_string /etc/backhaul/server.toml bind_addr "127.0.0.1:${SERVER_RAW_PORT}"
  set_toml_string /etc/backhaul/server.toml transport "tcpmux"

  python3 - "$TCP_TLS_DOMAIN" /etc/haproxy/haproxy.cfg <<'PY'
from pathlib import Path
import re, sys

domain = sys.argv[1]
path = Path(sys.argv[2])
text = path.read_text()

if '# phase3-tcptls-begin' not in text:
    acl_line = re.search(r'(?m)^(\s*)acl\s+is_backbone\s+req\.ssl_sni\s+-i\s+.+$', text)
    if not acl_line:
        raise SystemExit('[x] Could not locate HAProxy backbone SNI ACL.')
    indent = acl_line.group(1)
    insertion = f"{acl_line.group(0)}\n{indent}# phase3-tcptls-begin\n{indent}acl is_tcptls req.ssl_sni -i {domain}\n{indent}use_backend backhaul_tcptls if is_tcptls\n{indent}# phase3-tcptls-end"
    text = text[:acl_line.start()] + insertion + text[acl_line.end():]

if 'backend backhaul_tcptls' not in text:
    marker = re.search(r'(?m)^backend\s+backhaul_wss\s*$', text)
    if not marker:
        raise SystemExit('[x] Could not locate HAProxy backhaul_wss backend.')
    block = (
        'backend backhaul_tcptls\n'
        '    mode tcp\n'
        '    server tcptls_control 127.0.0.1:9444\n\n'
    )
    text = text[:marker.start()] + block + text[marker.start():]

path.write_text(text)
PY

  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null

  systemctl daemon-reload
  systemctl enable backhaul-tcptls.service >/dev/null 2>&1
  systemctl restart backhaul-tcptls.service
  systemctl restart backhaul.service
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy

  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow from "$FOREIGN_IP" to any port 3080 proto tcp >/dev/null 2>&1 || true
  fi

  sleep 3
  ss -lntp 2>/dev/null | grep -q "127.0.0.1:${SERVER_RAW_PORT}" || { echo "[x] Backhaul TCPMux raw loopback listener missing." >&2; exit 7; }
  ss -lntp 2>/dev/null | grep -q "127.0.0.1:${SERVER_TLS_PORT}" || { echo "[x] stunnel TLS loopback listener missing." >&2; exit 7; }
  if ss -lntp 2>/dev/null | grep -q ':3080 '; then
    echo "[x] Legacy raw TCPMux :3080 is still listening." >&2
    exit 7
  fi

  tls_probe "$TCP_TLS_DOMAIN" 127.0.0.1 443 || { echo "[x] HAProxy -> Phase 3 TLS handshake/certificate probe failed." >&2; exit 7; }

  cat > "$PHASE3_MARKER" <<EOF_MARKER
role=iran
tcp_tls_domain=$TCP_TLS_DOMAIN
public_port=443
stunnel_port=$SERVER_TLS_PORT
backhaul_raw_port=$SERVER_RAW_PORT
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_MARKER
  chmod 0600 "$PHASE3_MARKER"

  echo "[+] Phase 3 Iran TCPMux TLS ingress ready."
  echo "[+] Public :443 SNI=$TCP_TLS_DOMAIN -> HAProxy -> stunnel :$SERVER_TLS_PORT -> Backhaul TCPMux :$SERVER_RAW_PORT."
  echo "[+] Legacy raw TCPMux :3080 is no longer listening."
  echo "[i] TCPMux will remain unavailable until Foreign receives the updated bundle and Phase 3 client config."
  echo "[i] Copy $BUNDLE to Foreign, then run this same Phase 3 script there."
else
  [[ -n "$TCP_TLS_DOMAIN" ]] || { echo "[x] TCP_TLS_DOMAIN missing from bundle. Run Phase 3 on Iran first and copy the updated bundle." >&2; exit 8; }
  valid_domain "$TCP_TLS_DOMAIN" || { echo "[x] Invalid TCP_TLS_DOMAIN in bundle." >&2; exit 8; }
  [[ -f /etc/backhaul/client.toml ]] || { echo "[x] Missing /etc/backhaul/client.toml" >&2; exit 5; }

  resolved="$(getent ahostsv4 "$TCP_TLS_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
  [[ "$resolved" == "$IRAN_IP" ]] || { echo "[x] $TCP_TLS_DOMAIN resolves to ${resolved:-none}; expected Iran IP $IRAN_IP" >&2; exit 5; }

  tls_probe "$TCP_TLS_DOMAIN" "$TCP_TLS_DOMAIN" 443 || { echo "[x] Phase 3 public TLS endpoint is not reachable/valid from Foreign." >&2; exit 6; }

  init_backup
  backup_path /etc/backhaul/client.toml
  backup_path "$BUNDLE"
  backup_path "$STUNNEL_CONF"
  backup_path "$STUNNEL_UNIT"
  backup_path "$BACKHAUL_DROPIN"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y stunnel4 ca-certificates python3

  install -d -m 0755 /etc/stunnel /etc/systemd/system/backhaul.service.d

  cat > "$STUNNEL_CONF" <<CFG
foreground = yes
syslog = no
debug = notice
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[backhaul-tcpmux]
client = yes
accept = 127.0.0.1:${CLIENT_LOCAL_PORT}
connect = ${TCP_TLS_DOMAIN}:443
verifyChain = yes
CAfile = /etc/ssl/certs/ca-certificates.crt
checkHost = ${TCP_TLS_DOMAIN}
sni = ${TCP_TLS_DOMAIN}
sslVersionMin = TLSv1.2
TIMEOUTconnect = 10
TIMEOUTclose = 5
TIMEOUTidle = 43200
CFG
  chmod 0600 "$STUNNEL_CONF"

  cat > "$STUNNEL_UNIT" <<UNIT
[Unit]
Description=Phase 3 TLS client wrapper for Backhaul TCPMux
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/stunnel ${STUNNEL_CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  cat > "$BACKHAUL_DROPIN" <<'UNIT'
[Unit]
After=backhaul-tcptls.service
Requires=backhaul-tcptls.service
UNIT

  set_toml_string /etc/backhaul/client.toml remote_addr "127.0.0.1:${CLIENT_LOCAL_PORT}"
  set_toml_string /etc/backhaul/client.toml transport "tcpmux"

  systemctl daemon-reload
  systemctl enable backhaul-tcptls.service >/dev/null 2>&1
  systemctl restart backhaul-tcptls.service
  systemctl restart backhaul.service

  sleep 4
  systemctl is-active --quiet backhaul-tcptls.service || { echo "[x] Phase 3 stunnel client service is not active." >&2; exit 9; }
  systemctl is-active --quiet backhaul.service || { echo "[x] Backhaul TCPMux client is not active." >&2; exit 9; }
  ss -lntp 2>/dev/null | grep -q "127.0.0.1:${CLIENT_LOCAL_PORT}" || { echo "[x] Foreign stunnel loopback listener missing." >&2; exit 9; }

  cat > "$PHASE3_MARKER" <<EOF_MARKER
role=foreign
tcp_tls_domain=$TCP_TLS_DOMAIN
public_port=443
local_stunnel_port=$CLIENT_LOCAL_PORT
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_MARKER
  chmod 0600 "$PHASE3_MARKER"

  echo "[+] Phase 3 Foreign TCPMux client wrapper ready."
  echo "[+] Backhaul TCPMux now dials local stunnel :$CLIENT_LOCAL_PORT; stunnel verifies $TCP_TLS_DOMAIN and connects via public :443."
  echo "[i] Run the Phase 3 verifier, then tunnel-diagnose --deep on Iran."
fi

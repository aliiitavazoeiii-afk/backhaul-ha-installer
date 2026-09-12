#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-prepare}"
case "$MODE" in prepare|activate|status) ;; *) echo "Usage: $0 prepare|activate|status"; exit 2 ;; esac

XRAY_DIR="/usr/local/lib/xhttp-reality"
CONFIG_DIR="/etc/xhttp-reality"
SERVER_JSON="$CONFIG_DIR/server.json"
CLIENT_ENV="/root/xhttp-reality-client.env"
SERVER_ENV="/root/xhttp-reality-server-secrets.env"
DECOY_ENV="$CONFIG_DIR/decoy.env"
XRAY_SERVICE="xhttp-reality-server.service"
DECOY_SERVICE="xhttp-reality-decoy.service"
CADDY_VERSION="2.11.4"
DECOY_ZONE="${DECOY_ZONE:-nip.io}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
for cmd in curl python3 systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd"; exit 1; }
done
[[ -x "$XRAY_DIR/xray" && -f "$SERVER_JSON" && -f "$CLIENT_ENV" && -f "$SERVER_ENV" ]] || {
  echo "Current Foreign XHTTP/REALITY installation not found."; exit 1;
}

read_decoy_env() {
  [[ -f "$DECOY_ENV" ]] || return 1
  DECOY_DOMAIN="$(python3 - "$DECOY_ENV" <<'PY'
import ast, sys
vals={}
for line in open(sys.argv[1]):
    if "=" not in line or line.lstrip().startswith("#"):
        continue
    k,v=line.strip().split("=",1)
    try: vals[k]=ast.literal_eval(v)
    except Exception: vals[k]=v.strip("'\"")
print(vals.get("DECOY_DOMAIN",""))
PY
)"
  PUBLIC_IP="$(python3 - "$DECOY_ENV" <<'PY'
import ast, sys
vals={}
for line in open(sys.argv[1]):
    if "=" not in line or line.lstrip().startswith("#"):
        continue
    k,v=line.strip().split("=",1)
    try: vals[k]=ast.literal_eval(v)
    except Exception: vals[k]=v.strip("'\"")
print(vals.get("PUBLIC_IP",""))
PY
)"
  [[ -n "$DECOY_DOMAIN" && -n "$PUBLIC_IP" ]]
}

decoy_test() {
  curl -4 -fsS --max-time 12 --connect-timeout 5 \
    --resolve "${DECOY_DOMAIN}:8443:127.0.0.1" \
    "https://${DECOY_DOMAIN}:8443/" >/dev/null
}

if [[ "$MODE" == "status" ]]; then
  if read_decoy_env; then
    echo "Decoy SNI: $DECOY_DOMAIN"
    echo "Public IP: $PUBLIC_IP"
    systemctl is-active "$DECOY_SERVICE" || true
    if decoy_test; then echo "Decoy TLS: OK"; else echo "Decoy TLS: FAILED"; fi
  else
    echo "Decoy not prepared."
  fi
  systemctl is-active "$XRAY_SERVICE" || true
  exit 0
fi

if [[ "$MODE" == "prepare" ]]; then
  if read_decoy_env && systemctl is-active --quiet "$DECOY_SERVICE" && decoy_test; then
    echo "Existing decoy is already ready."
    echo "DECOY_SNI=$DECOY_DOMAIN"
    echo "No Xray/REALITY setting changed."
    exit 0
  fi

  PUBLIC_IP="$(curl -4 -fsS --max-time 12 --connect-timeout 5 https://icanhazip.com | tr -d '[:space:]')"
  python3 - "$PUBLIC_IP" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY

  if [[ -n "${REALITY_DECOY_DOMAIN:-}" ]]; then
    DECOY_DOMAIN="$REALITY_DECOY_DOMAIN"
  else
    DASH_IP="${PUBLIC_IP//./-}"
    TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(4))
PY
)"
    DECOY_DOMAIN="edge-${TOKEN}.${DASH_IP}.${DECOY_ZONE}"
  fi

  echo "Preparing same-server TLS decoy:"
  echo "  Public IP : $PUBLIC_IP"
  echo "  Domain    : $DECOY_DOMAIN"

  RESOLVED="$(python3 - "$DECOY_DOMAIN" "$PUBLIC_IP" <<'PY'
import socket, sys
name, expected = sys.argv[1:]
ips=sorted({x[4][0] for x in socket.getaddrinfo(name, 80, socket.AF_INET, socket.SOCK_STREAM)})
print(",".join(ips))
if expected not in ips:
    raise SystemExit(1)
PY
)" || {
    echo "ERROR: $DECOY_DOMAIN does not resolve to $PUBLIC_IP"; exit 1;
  }
  echo "  DNS       : $RESOLVED"

  python3 - <<'PY'
import socket
for host,port in [('0.0.0.0',80),('127.0.0.1',8443)]:
    s=socket.socket()
    s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    try: s.bind((host,port))
    except OSError as e:
        raise SystemExit(f'Port {host}:{port} unavailable: {e}')
    finally: s.close()
PY

  case "$(uname -m)" in
    x86_64|amd64)
      CADDY_ASSET="caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
      CADDY_SHA256="527fbf917c39189a1e3b31d34fa955601680b2d5c8055d2a87b8b9588dec7bb9"
      ;;
    aarch64|arm64)
      CADDY_ASSET="caddy_${CADDY_VERSION}_linux_arm64.tar.gz"
      CADDY_SHA256="52d42ae12b3462097e9868da6dfed3c9648ae12edd3b3638102312af84cb6904"
      ;;
    *) echo "Unsupported architecture for decoy Caddy: $(uname -m)"; exit 1 ;;
  esac

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  URL="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/${CADDY_ASSET}"
  echo "Downloading Caddy v${CADDY_VERSION}..."
  curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 180 \
    "$URL" -o "$TMP/caddy.tar.gz"

  python3 - "$TMP/caddy.tar.gz" "$CADDY_SHA256" "$TMP" <<'PY'
import hashlib, os, sys, tarfile
src, expected, dst = sys.argv[1:]
h=hashlib.sha256(open(src,'rb').read()).hexdigest()
if h != expected:
    raise SystemExit(f'Caddy SHA256 mismatch: {h}')
with tarfile.open(src,'r:gz') as t:
    t.extractall(dst)
c=os.path.join(dst,'caddy')
if not os.path.isfile(c):
    raise SystemExit('caddy binary missing from archive')
PY
  install -m 0755 "$TMP/caddy" "$XRAY_DIR/caddy"

  mkdir -p /var/lib/xhttp-reality-caddy "$CONFIG_DIR"
  chmod 700 /var/lib/xhttp-reality-caddy

  cat >"$CONFIG_DIR/Caddyfile" <<EOF
{
    admin off
    auto_https disable_redirects
    http_port 80
    https_port 8443
}

http://${DECOY_DOMAIN}:80 {
    respond "OK" 200
}

https://${DECOY_DOMAIN}:8443 {
    bind 127.0.0.1
    tls {
        issuer acme {
            dir https://acme-v02.api.letsencrypt.org/directory
            disable_tlsalpn_challenge
        }
    }
    respond "Welcome" 200
}
EOF

  "$XRAY_DIR/caddy" validate --config "$CONFIG_DIR/Caddyfile" --adapter caddyfile

  cat >/etc/systemd/system/${DECOY_SERVICE} <<EOF
[Unit]
Description=Local HTTPS camouflage target for XHTTP REALITY
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/var/lib/xhttp-reality-caddy
Environment=XDG_DATA_HOME=/var/lib/xhttp-reality-caddy/data
Environment=XDG_CONFIG_HOME=/var/lib/xhttp-reality-caddy/config
ExecStart=$XRAY_DIR/caddy run --config $CONFIG_DIR/Caddyfile --adapter caddyfile
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=/var/lib/xhttp-reality-caddy

[Install]
WantedBy=multi-user.target
EOF

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp
  fi

  systemctl daemon-reload
  systemctl enable --now "$DECOY_SERVICE"

  echo "Waiting for public certificate..."
  OK=0
  for _ in $(seq 1 45); do
    if decoy_test; then OK=1; break; fi
    sleep 2
  done
  if [[ "$OK" != "1" ]]; then
    echo "ERROR: decoy TLS certificate did not become valid."
    journalctl -u "$DECOY_SERVICE" -n 60 --no-pager || true
    systemctl disable --now "$DECOY_SERVICE" || true
    exit 1
  fi

  cat >"$DECOY_ENV" <<EOF
DECOY_DOMAIN='${DECOY_DOMAIN}'
PUBLIC_IP='${PUBLIC_IP}'
DECOY_TARGET='127.0.0.1:8443'
EOF
  chmod 600 "$DECOY_ENV"

  echo
  echo "============================================================"
  echo "FOREIGN DECOY PREPARED - NO REALITY CHANGE YET"
  echo "DECOY_SNI=$DECOY_DOMAIN"
  echo "Next: stage this SNI on Iran, then run this script with: activate"
  echo "============================================================"
  exit 0
fi

read_decoy_env || { echo "Run '$0 prepare' first."; exit 1; }
systemctl is-active --quiet "$DECOY_SERVICE" || { echo "Decoy service is not active."; exit 1; }
decoy_test || { echo "Decoy TLS validation failed; refusing REALITY change."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/lib/xhttp-reality-backups/$STAMP-hardening"
mkdir -p "$BACKUP_DIR"
chmod 700 /var/lib/xhttp-reality-backups "$BACKUP_DIR"
cp -a "$SERVER_JSON" "$BACKUP_DIR/server.json"
cp -a "$CLIENT_ENV" "$BACKUP_DIR/xhttp-reality-client.env"
cp -a "$SERVER_ENV" "$BACKUP_DIR/xhttp-reality-server-secrets.env"
[[ -d /etc/systemd/system/${XRAY_SERVICE}.d ]] && cp -a /etc/systemd/system/${XRAY_SERVICE}.d "$BACKUP_DIR/xray-dropins" || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SERVER_JSON" "$TMP/server.json" "$DECOY_DOMAIN" <<'PY'
import json, sys
src,dst,sni=sys.argv[1:]
obj=json.load(open(src))
ins=obj.get("inbounds") or []
if len(ins)!=1:
    raise SystemExit("Unexpected server config: expected one inbound")
rs=ins[0].setdefault("streamSettings",{}).setdefault("realitySettings",{})
rs["target"]="127.0.0.1:8443"
rs["serverNames"]=[sni]
with open(dst,"w") as f:
    json.dump(obj,f,indent=2)
    f.write("\n")
PY
"$XRAY_DIR/xray" run -test -c "$TMP/server.json" >/dev/null

python3 - "$CLIENT_ENV" "$TMP/client.env" "$DECOY_DOMAIN" <<'PY'
import sys
src,dst,sni=sys.argv[1:]
lines=open(src).read().splitlines()
out=[]; seen=False
for line in lines:
    if line.startswith("SNI="):
        out.append("SNI="+repr(sni)); seen=True
    else: out.append(line)
if not seen: out.append("SNI="+repr(sni))
open(dst,"w").write("\n".join(out)+"\n")
PY
python3 - "$SERVER_ENV" "$TMP/server.env" <<'PY'
import sys
src,dst=sys.argv[1:]
lines=open(src).read().splitlines()
out=[]; seen=False
for line in lines:
    if line.startswith("TARGET="):
        out.append("TARGET='127.0.0.1:8443'"); seen=True
    else: out.append(line)
if not seen: out.append("TARGET='127.0.0.1:8443'")
open(dst,"w").write("\n".join(out)+"\n")
PY

rollback() {
  echo "Activation failed; rolling back Foreign REALITY..."
  cp -a "$BACKUP_DIR/server.json" "$SERVER_JSON" || true
  cp -a "$BACKUP_DIR/xhttp-reality-client.env" "$CLIENT_ENV" || true
  cp -a "$BACKUP_DIR/xhttp-reality-server-secrets.env" "$SERVER_ENV" || true
  rm -rf /etc/systemd/system/${XRAY_SERVICE}.d
  if [[ -d "$BACKUP_DIR/xray-dropins" ]]; then
    cp -a "$BACKUP_DIR/xray-dropins" /etc/systemd/system/${XRAY_SERVICE}.d
  fi
  systemctl daemon-reload || true
  systemctl restart "$XRAY_SERVICE" || true
  echo "Rollback backup: $BACKUP_DIR"
}
trap rollback ERR

install -m 0600 "$TMP/server.json" "$SERVER_JSON"
install -m 0600 "$TMP/client.env" "$CLIENT_ENV"
install -m 0600 "$TMP/server.env" "$SERVER_ENV"

mkdir -p /etc/systemd/system/${XRAY_SERVICE}.d
cat >/etc/systemd/system/${XRAY_SERVICE}.d/10-hardening.conf <<'EOF'
[Service]
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
EOF

echo
echo "Activating REALITY local decoy. Immediately activate the staged SNI on Iran after this succeeds."
systemctl daemon-reload
systemctl restart "$XRAY_SERVICE"
sleep 2
systemctl is-active --quiet "$XRAY_SERVICE"

curl -4 -fsS --max-time 12 --connect-timeout 5 \
  --resolve "${DECOY_DOMAIN}:443:127.0.0.1" \
  "https://${DECOY_DOMAIN}/" >/dev/null

trap - ERR
echo
echo "============================================================"
echo "FOREIGN REALITY HARDENING ACTIVE"
echo "NEW_SNI=$DECOY_DOMAIN"
echo "TARGET=127.0.0.1:8443"
echo "Credentials unchanged except SNI."
echo "Backup=$BACKUP_DIR"
echo "NOW ACTIVATE THE STAGED SNI ON IRAN."
echo "============================================================"

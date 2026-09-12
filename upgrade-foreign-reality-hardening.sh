#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-prepare}"
case "$MODE" in prepare|activate|status) ;; *) echo "Usage: $0 prepare|activate|status"; exit 2 ;; esac

XRAY_DIR="/usr/local/lib/xhttp-reality"
CONFIG_DIR="/etc/xhttp-reality"
SERVER_JSON="$CONFIG_DIR/server.json"
CLIENT_ENV="/root/xhttp-reality-client.env"
SERVER_ENV="/root/xhttp-reality-server-secrets.env"
CAMO_ENV="$CONFIG_DIR/camouflage.env"
XRAY_SERVICE="xhttp-reality-server.service"
DECOY_DIR="/usr/local/lib/xhttp-reality-decoy"
DECOY_CONFIG_DIR="/etc/xhttp-reality-decoy"
DECOY_STATE_DIR="/var/lib/xhttp-reality-decoy"
DECOY_SERVICE="xhttp-reality-decoy.service"
DECOY_PORT="${REALITY_DECOY_PORT:-8443}"
DECOY_ZONE="${DECOY_ZONE:-nip.io}"
EXPLICIT_DOMAIN="${REALITY_DECOY_DOMAIN:-}"
CADDY_VERSION="${CADDY_VERSION:-v2.11.4}"
CADDY_SHA256="${CADDY_SHA256:-}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
for cmd in curl python3 systemctl; do command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd"; exit 1; }; done
[[ -x "$XRAY_DIR/xray" && -f "$SERVER_JSON" && -f "$CLIENT_ENV" && -f "$SERVER_ENV" ]] || { echo "Current Foreign XHTTP/REALITY installation not found."; exit 1; }
[[ "$DECOY_PORT" =~ ^[0-9]+$ ]] && (( DECOY_PORT >= 1024 && DECOY_PORT <= 65535 )) || { echo "Invalid REALITY_DECOY_PORT: $DECOY_PORT"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)
    CADDY_ASSET="caddy_${CADDY_VERSION#v}_linux_amd64.tar.gz"
    [[ -n "$CADDY_SHA256" ]] || [[ "$CADDY_VERSION" != "v2.11.4" ]] || CADDY_SHA256="527fbf917c39189a1e3b31d34fa955601680b2d5c8055d2a87b8b9588dec7bb9"
    ;;
  aarch64|arm64)
    CADDY_ASSET="caddy_${CADDY_VERSION#v}_linux_arm64.tar.gz"
    [[ -n "$CADDY_SHA256" ]] || [[ "$CADDY_VERSION" != "v2.11.4" ]] || CADDY_SHA256="52d42ae12b3462097e9868da6dfed3c9648ae12edd3b3638102312af84cb6904"
    ;;
  *) echo "Unsupported architecture for decoy: $(uname -m)"; exit 1 ;;
esac
[[ -n "$CADDY_SHA256" ]] || { echo "No trusted Caddy SHA256 for $CADDY_VERSION/$CADDY_ASSET."; echo "Set CADDY_SHA256 explicitly for a custom version."; exit 1; }

read_env_value() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY'
import ast, sys
path,key=sys.argv[1:]
for line in open(path, encoding="utf-8"):
    if line.startswith(key+"="):
        raw=line.split("=",1)[1].strip()
        try: print(ast.literal_eval(raw))
        except Exception: print(raw.strip("'\""))
        raise SystemExit
print("")
PY
}

read_camo_env() {
  [[ -f "$CAMO_ENV" ]] || return 1
  read -r CAMOUFLAGE_HOST CAMOUFLAGE_TARGET PUBLIC_IP < <(python3 - "$CAMO_ENV" <<'PY'
import ast, sys
vals={}
for line in open(sys.argv[1], encoding="utf-8"):
    if "=" not in line or line.lstrip().startswith("#"): continue
    k,v=line.strip().split("=",1)
    try: vals[k]=ast.literal_eval(v)
    except Exception: vals[k]=v.strip("'\"")
print(vals.get("CAMOUFLAGE_HOST",""), vals.get("CAMOUFLAGE_TARGET",""), vals.get("PUBLIC_IP",""))
PY
)
  [[ -n "$CAMOUFLAGE_HOST" && -n "$CAMOUFLAGE_TARGET" ]]
}

validate_domain_points_here() {
  local host="$1" ip="$2"
  python3 - "$host" "$ip" <<'PY'
import socket, sys
host, expected=sys.argv[1:]
ips=sorted({x[4][0] for x in socket.getaddrinfo(host,443,socket.AF_INET,socket.SOCK_STREAM)})
print("Resolved IPv4:", ", ".join(ips) or "(none)")
if expected not in ips: raise SystemExit(f"{host} does not resolve to this Foreign IPv4 {expected}")
PY
}

public_ipv4() {
  python3 - <<'PY'
import ipaddress, subprocess
for url in ("https://api.ipify.org","https://icanhazip.com","https://ifconfig.co/ip"):
    try:
        p=subprocess.run(["curl","-4","-fsS","--max-time","8","--connect-timeout","4",url],text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
        raw=p.stdout.strip()
        if p.returncode == 0 and ipaddress.ip_address(raw).version == 4:
            print(raw); raise SystemExit
    except Exception: pass
raise SystemExit("Could not determine public IPv4")
PY
}

ptr_candidate() {
  local ip="$1"
  python3 - "$ip" <<'PY'
import re, socket, sys
ip=sys.argv[1]
try: host=socket.gethostbyaddr(ip)[0].rstrip(".").lower()
except Exception: raise SystemExit(1)
if not re.fullmatch(r"[a-z0-9.-]+",host) or "." not in host: raise SystemExit(1)
try: ips={x[4][0] for x in socket.getaddrinfo(host,443,socket.AF_INET,socket.SOCK_STREAM)}
except Exception: raise SystemExit(1)
if ip not in ips: raise SystemExit(1)
print(host)
PY
}

generated_candidate() {
  local ip="$1"
  python3 - "$ip" "$DECOY_ZONE" <<'PY'
import secrets, sys
ip,zone=sys.argv[1:]
print(f"edge-{secrets.token_hex(4)}.{ip}.{zone}")
PY
}

port80_available() {
  if systemctl is-active --quiet "$DECOY_SERVICE" 2>/dev/null; then return 0; fi
  python3 - <<'PY'
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
try: s.bind(("0.0.0.0",80))
except OSError as e: print(f"TCP 80 is already in use: {e}"); raise SystemExit(1)
finally: s.close()
PY
}

install_caddy() {
  mkdir -p "$DECOY_DIR" "$DECOY_CONFIG_DIR" "$DECOY_STATE_DIR"
  chmod 700 "$DECOY_CONFIG_DIR" "$DECOY_STATE_DIR"
  if [[ -x "$DECOY_DIR/caddy" ]] && "$DECOY_DIR/caddy" version 2>/dev/null | grep -q "${CADDY_VERSION#v}"; then return 0; fi
  local tmp url
  tmp="$(mktemp -d)"
  url="https://github.com/caddyserver/caddy/releases/download/${CADDY_VERSION}/${CADDY_ASSET}"
  echo "Downloading verified Caddy ${CADDY_VERSION}..."
  curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$tmp/caddy.tar.gz"
  python3 - "$tmp/caddy.tar.gz" "$CADDY_SHA256" <<'PY'
import hashlib, sys
p,expected=sys.argv[1:]; got=hashlib.sha256(open(p,"rb").read()).hexdigest()
if got != expected: raise SystemExit(f"Caddy SHA256 mismatch: got {got}, expected {expected}")
print("Caddy SHA256 verified:",got)
PY
  mkdir -p "$tmp/out"
  python3 - "$tmp/caddy.tar.gz" "$tmp/out/caddy" <<'PY'
import os,sys,tarfile
src,dst=sys.argv[1:]
with tarfile.open(src,"r:gz") as t:
    member=next((m for m in t.getmembers() if m.isfile() and os.path.basename(m.name)=="caddy"),None)
    if not member: raise SystemExit("caddy binary not found in archive")
    f=t.extractfile(member); open(dst,"wb").write(f.read())
PY
  install -m 0755 "$tmp/out/caddy" "$DECOY_DIR/caddy"
  rm -rf "$tmp"
}

write_decoy_config() {
  local host="$1"
  cat >"$DECOY_CONFIG_DIR/Caddyfile" <<EOF
{
    admin off
    auto_https disable_redirects
}

https://${host}:${DECOY_PORT} {
    bind 127.0.0.1
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
    header {
        -Server
        Cache-Control "no-store"
        X-Content-Type-Options "nosniff"
    }
    @root path /
    respond @root "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Service</title></head><body><h1>Service online</h1></body></html>" 200
    respond "Not Found" 404
}
EOF
  chmod 600 "$DECOY_CONFIG_DIR/Caddyfile"
  cat >/etc/systemd/system/${DECOY_SERVICE} <<EOF
[Unit]
Description=Local HTTPS decoy for XHTTP REALITY
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XDG_DATA_HOME=${DECOY_STATE_DIR}/data
Environment=XDG_CONFIG_HOME=${DECOY_STATE_DIR}/config
ExecStart=${DECOY_DIR}/caddy run --config ${DECOY_CONFIG_DIR}/Caddyfile --adapter caddyfile
ExecReload=${DECOY_DIR}/caddy reload --config ${DECOY_CONFIG_DIR}/Caddyfile --adapter caddyfile --force
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=${DECOY_STATE_DIR}
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

wait_decoy_tls() {
  local host="$1" i
  for i in $(seq 1 30); do
    if curl -4 -fsS --max-time 5 --connect-timeout 2 --resolve "${host}:${DECOY_PORT}:127.0.0.1" "https://${host}:${DECOY_PORT}/" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

start_candidate() {
  local host="$1" ip="$2"
  echo; echo "Preparing same-server HTTPS decoy: $host -> $ip"
  validate_domain_points_here "$host" "$ip"
  write_decoy_config "$host"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then ufw allow 80/tcp >/dev/null || true; fi
  systemctl daemon-reload
  systemctl enable "$DECOY_SERVICE" >/dev/null
  systemctl restart "$DECOY_SERVICE"
  if wait_decoy_tls "$host"; then echo "Local decoy TLS certificate: OK"; return 0; fi
  echo "Decoy certificate validation failed for $host."
  journalctl -u "$DECOY_SERVICE" -n 30 --no-pager || true
  systemctl stop "$DECOY_SERVICE" || true
  return 1
}

fallback_test() {
  local host="$1"
  curl -4 -fsS --max-time 12 --connect-timeout 5 --resolve "${host}:443:127.0.0.1" "https://${host}/" >/dev/null
}

if [[ "$MODE" == "status" ]]; then
  echo "XHTTP REALITY FOREIGN HARDENING STATUS"
  echo "Current SNI    : $(read_env_value "$CLIENT_ENV" SNI)"
  echo "Current target : $(read_env_value "$SERVER_ENV" TARGET)"
  if read_camo_env; then
    echo "Decoy SNI      : $CAMOUFLAGE_HOST"
    echo "Decoy target   : $CAMOUFLAGE_TARGET"
    echo "Foreign IPv4   : ${PUBLIC_IP:-unknown}"
    systemctl is-active "$DECOY_SERVICE" 2>/dev/null || true
    if systemctl is-active --quiet "$DECOY_SERVICE" && wait_decoy_tls "$CAMOUFLAGE_HOST"; then echo "Decoy TLS      : OK"; else echo "Decoy TLS      : FAILED"; fi
  else
    echo "Decoy          : not prepared"
  fi
  systemctl is-active "$XRAY_SERVICE" || true
  exit 0
fi

if [[ "$MODE" == "prepare" ]]; then
  current_target="$(read_env_value "$SERVER_ENV" TARGET)"
  if [[ "$current_target" == "127.0.0.1:${DECOY_PORT}" ]] && read_camo_env; then
    echo "Same-server decoy is already active."
    echo "NEW_SNI=$CAMOUFLAGE_HOST"
    echo "NEW_TARGET=$CAMOUFLAGE_TARGET"
    exit 0
  fi
  port80_available || { echo "Cannot prepare public TLS decoy while TCP 80 is occupied."; echo "No live REALITY settings were changed."; exit 1; }
  install_caddy
  PUBLIC_IP="$(public_ipv4)"
  echo "Foreign public IPv4: $PUBLIC_IP"
  candidates=()
  if [[ -n "$EXPLICIT_DOMAIN" ]]; then
    candidates+=("$EXPLICIT_DOMAIN")
  else
    if ptr="$(ptr_candidate "$PUBLIC_IP" 2>/dev/null)"; then candidates+=("$ptr"); echo "Provider/PTR candidate: $ptr"; fi
    candidates+=("$(generated_candidate "$PUBLIC_IP")")
  fi
  selected=""
  for candidate in "${candidates[@]}"; do if start_candidate "$candidate" "$PUBLIC_IP"; then selected="$candidate"; break; fi; done
  [[ -n "$selected" ]] || { echo; echo "Could not provision a same-server public TLS decoy."; echo "Check that TCP 80 reaches this VPS, or set REALITY_DECOY_DOMAIN to a DNS-only hostname pointing directly to $PUBLIC_IP."; echo "No live REALITY settings were changed."; exit 1; }
  cat >"$CAMO_ENV" <<EOF
CAMOUFLAGE_HOST='${selected}'
CAMOUFLAGE_TARGET='127.0.0.1:${DECOY_PORT}'
PUBLIC_IP='${PUBLIC_IP}'
DECOY_PORT='${DECOY_PORT}'
CADDY_VERSION='${CADDY_VERSION}'
EOF
  chmod 600 "$CAMO_ENV"
  echo; echo "============================================================"
  echo "FOREIGN SAME-SERVER DECOY PREPARED - LIVE REALITY UNCHANGED"
  echo "NEW_SNI=$selected"
  echo "NEW_TARGET=127.0.0.1:${DECOY_PORT}"
  echo "Decoy HTTPS is loopback-only; TCP 80 stays reachable for ACME renewal."
  echo "For an existing Iran server: stage NEW_SNI on Iran BEFORE activate."
  echo "============================================================"
  exit 0
fi

read_camo_env || { echo "Run '$0 prepare' first."; exit 1; }
systemctl is-active --quiet "$DECOY_SERVICE" || { echo "Decoy service is not active."; exit 1; }
wait_decoy_tls "$CAMOUFLAGE_HOST" || { echo "Decoy TLS validation failed."; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/lib/xhttp-reality-backups/$STAMP-hardening"
mkdir -p "$BACKUP_DIR"; chmod 700 /var/lib/xhttp-reality-backups "$BACKUP_DIR"
cp -a "$SERVER_JSON" "$BACKUP_DIR/server.json"; cp -a "$CLIENT_ENV" "$BACKUP_DIR/xhttp-reality-client.env"; cp -a "$SERVER_ENV" "$BACKUP_DIR/xhttp-reality-server-secrets.env"
[[ -d /etc/systemd/system/${XRAY_SERVICE}.d ]] && cp -a /etc/systemd/system/${XRAY_SERVICE}.d "$BACKUP_DIR/xray-dropins" || true
cp -a "$CAMO_ENV" "$BACKUP_DIR/camouflage.env" || true
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 - "$SERVER_JSON" "$TMP/server.json" "$CAMOUFLAGE_HOST" "$CAMOUFLAGE_TARGET" <<'PY'
import json, sys
src,dst,sni,target=sys.argv[1:]; obj=json.load(open(src)); ins=obj.get("inbounds") or []
if len(ins)!=1: raise SystemExit("Unexpected server config: expected one inbound")
rs=ins[0].setdefault("streamSettings",{}).setdefault("realitySettings",{}); rs["target"]=target; rs["serverNames"]=[sni]
with open(dst,"w") as f: json.dump(obj,f,indent=2); f.write("\n")
PY
"$XRAY_DIR/xray" run -test -c "$TMP/server.json" >/dev/null
python3 - "$CLIENT_ENV" "$TMP/client.env" "$CAMOUFLAGE_HOST" <<'PY'
import sys
src,dst,sni=sys.argv[1:]; lines=open(src).read().splitlines(); out=[]; seen=False
for line in lines:
    if line.startswith("SNI="): out.append("SNI="+repr(sni)); seen=True
    else: out.append(line)
if not seen: out.append("SNI="+repr(sni))
open(dst,"w").write("\n".join(out)+"\n")
PY
python3 - "$SERVER_ENV" "$TMP/server.env" "$CAMOUFLAGE_TARGET" "$CAMOUFLAGE_HOST" <<'PY'
import sys
src,dst,target,sni=sys.argv[1:]; lines=open(src).read().splitlines(); out=[]; seen_t=False; seen_s=False
for line in lines:
    if line.startswith("TARGET="): out.append("TARGET="+repr(target)); seen_t=True
    elif line.startswith("DECOY_SNI="): out.append("DECOY_SNI="+repr(sni)); seen_s=True
    else: out.append(line)
if not seen_t: out.append("TARGET="+repr(target))
if not seen_s: out.append("DECOY_SNI="+repr(sni))
open(dst,"w").write("\n".join(out)+"\n")
PY
rollback() {
  echo "Activation failed; rolling back Foreign REALITY..."
  cp -a "$BACKUP_DIR/server.json" "$SERVER_JSON" || true; cp -a "$BACKUP_DIR/xhttp-reality-client.env" "$CLIENT_ENV" || true; cp -a "$BACKUP_DIR/xhttp-reality-server-secrets.env" "$SERVER_ENV" || true
  rm -rf /etc/systemd/system/${XRAY_SERVICE}.d; [[ -d "$BACKUP_DIR/xray-dropins" ]] && cp -a "$BACKUP_DIR/xray-dropins" /etc/systemd/system/${XRAY_SERVICE}.d || true
  systemctl daemon-reload || true; systemctl restart "$XRAY_SERVICE" || true; echo "Rollback backup: $BACKUP_DIR"
}
trap rollback ERR
install -m 0600 "$TMP/server.json" "$SERVER_JSON"; install -m 0600 "$TMP/client.env" "$CLIENT_ENV"; install -m 0600 "$TMP/server.env" "$SERVER_ENV"
mkdir -p /etc/systemd/system/${XRAY_SERVICE}.d
cat >/etc/systemd/system/${XRAY_SERVICE}.d/10-hardening.conf <<'HARDENING_EOF'
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
HARDENING_EOF
echo; echo "Activating same-server REALITY camouflage."
echo "Existing Iran clients using the old SNI will stop until their selected node is switched to NEW_SNI."
systemctl daemon-reload; systemctl restart "$XRAY_SERVICE"; sleep 2; systemctl is-active --quiet "$XRAY_SERVICE"; fallback_test "$CAMOUFLAGE_HOST"
trap - ERR
echo; echo "============================================================"
echo "FOREIGN REALITY SAME-SERVER HARDENING ACTIVE"
echo "NEW_SNI=$CAMOUFLAGE_HOST"; echo "TARGET=$CAMOUFLAGE_TARGET"; echo "Credentials unchanged except SNI/target."; echo "Unauthenticated TLS fallback: verified through Foreign :443."; echo "Backup=$BACKUP_DIR"
echo "============================================================"

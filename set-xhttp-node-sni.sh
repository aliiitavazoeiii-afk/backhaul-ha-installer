#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
STAGE_ROOT="$STATE_DIR/sni-stage"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  xhttp-dual-set-sni f1|f2 <new-sni>                 # stage + activate now
  xhttp-dual-set-sni --stage f1|f2 <new-sni>         # no live change
  xhttp-dual-set-sni --activate-stage f1|f2           # activate prepared SNI
EOF
}

MODE="immediate"
if [[ "${1:-}" == "--stage" ]]; then
  MODE="stage"; shift
elif [[ "${1:-}" == "--activate-stage" ]]; then
  MODE="activate"; shift
fi

NODE="${1:-}"
case "$NODE" in
  f1) NUM=1 ;;
  f2) NUM=2 ;;
  *) usage; exit 2 ;;
esac

NODE_JSON="$CONFIG_DIR/${NODE}.json"
ENV_FILE="$CONFIG_DIR/foreign${NUM}.env"
SERVICE="xhttp-dual-${NODE}.service"
STAGE_DIR="$STAGE_ROOT/$NODE"

[[ -x "$INSTALL_DIR/xray" && -f "$NODE_JSON" && -f "$ENV_FILE" ]] || {
  echo "Missing XHTTP Dual files for $NODE."; exit 1;
}

stage_sni() {
  local new_sni="$1"
  [[ "$new_sni" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid SNI hostname."; exit 2; }
  mkdir -p "$STAGE_DIR"
  chmod 700 "$STATE_DIR" "$STAGE_ROOT" "$STAGE_DIR" 2>/dev/null || true

  python3 - "$NODE_JSON" "$STAGE_DIR/${NODE}.json" "$new_sni" <<'PY'
import json, sys
src, dst, sni = sys.argv[1:]
with open(src) as f:
    obj = json.load(f)
outs = obj.get("outbounds") or []
if len(outs) != 1:
    raise SystemExit("Unexpected node config: expected exactly one outbound")
rs = outs[0].setdefault("streamSettings", {}).setdefault("realitySettings", {})
rs["serverName"] = sni
with open(dst, "w") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
PY
  "$INSTALL_DIR/xray" run -test -c "$STAGE_DIR/${NODE}.json" >/dev/null

  python3 - "$ENV_FILE" "$STAGE_DIR/$(basename "$ENV_FILE")" "$new_sni" <<'PY'
import sys
src, dst, sni=sys.argv[1:]
lines=open(src).read().splitlines(); out=[]; seen=False
for line in lines:
    if line.startswith("SNI="):
        out.append("SNI="+repr(sni)); seen=True
    else:
        out.append(line)
if not seen: out.append("SNI="+repr(sni))
open(dst,"w").write("\n".join(out)+"\n")
PY
  printf '%s\n' "$new_sni" >"$STAGE_DIR/sni"
  chmod 600 "$STAGE_DIR/${NODE}.json" "$STAGE_DIR/$(basename "$ENV_FILE")" "$STAGE_DIR/sni"

  echo "SNI STAGED - NO LIVE CHANGE"
  echo "Node    : ${NODE^^}"
  echo "New SNI : $new_sni"
  echo "Activate: xhttp-dual-set-sni --activate-stage $NODE"
}

activate_stage() {
  [[ -f "$STAGE_DIR/${NODE}.json" && -f "$STAGE_DIR/$(basename "$ENV_FILE")" && -f "$STAGE_DIR/sni" ]] || {
    echo "No staged SNI for $NODE. Run --stage first."; exit 1;
  }
  local new_sni stamp backup_dir socks_port code egress
  new_sni="$(cat "$STAGE_DIR/sni")"
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$STATE_DIR/sni-backups/$stamp-$NODE"
  mkdir -p "$backup_dir"
  chmod 700 "$STATE_DIR" "$STATE_DIR/sni-backups" "$backup_dir" 2>/dev/null || true
  cp -a "$NODE_JSON" "$backup_dir/${NODE}.json"
  cp -a "$ENV_FILE" "$backup_dir/$(basename "$ENV_FILE")"

  rollback() {
    echo "SNI activation failed; rolling back $NODE..."
    cp -a "$backup_dir/${NODE}.json" "$NODE_JSON"
    cp -a "$backup_dir/$(basename "$ENV_FILE")" "$ENV_FILE"
    systemctl restart "$SERVICE" || true
    echo "Rollback: $backup_dir"
  }
  trap rollback ERR

  install -m 0600 "$STAGE_DIR/${NODE}.json" "$NODE_JSON"
  install -m 0600 "$STAGE_DIR/$(basename "$ENV_FILE")" "$ENV_FILE"
  systemctl restart "$SERVICE"
  sleep 2
  systemctl is-active --quiet "$SERVICE"

  socks_port="$(python3 - "$ENV_FILE" <<'PY'
import ast, sys
for line in open(sys.argv[1]):
    if line.startswith("SOCKS_PORT="):
        print(ast.literal_eval(line.split("=",1)[1].strip())); break
else: raise SystemExit(1)
PY
)"

  echo "Testing $NODE with staged SNI through 127.0.0.1:$socks_port ..."
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --connect-timeout 6 --socks5-hostname "127.0.0.1:${socks_port}" https://cp.cloudflare.com/generate_204 || true)"
  if [[ "$code" != "204" && "$code" != "200" ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --connect-timeout 6 --socks5-hostname "127.0.0.1:${socks_port}" https://connectivitycheck.gstatic.com/generate_204 || true)"
  fi
  [[ "$code" == "204" || "$code" == "200" ]] || { echo "End-to-end health test failed (HTTP ${code:-000})."; return 1; }

  egress="$(curl -4 -fsS --max-time 10 --connect-timeout 5 --socks5-hostname "127.0.0.1:${socks_port}" https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$egress" ]] || egress="(health OK; egress lookup unavailable)"

  trap - ERR
  rm -rf "$STAGE_DIR"
  echo
  echo "SNI ACTIVATION OK"
  echo "Node      : ${NODE^^}"
  echo "New SNI   : $new_sni"
  echo "Health    : HTTP $code"
  echo "Egress    : $egress"
  echo "Backup    : $backup_dir"
  echo "x-ui      : NOT restarted by this helper"
  echo "Controller: will observe recovery automatically"
}

case "$MODE" in
  stage)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    stage_sni "$2"
    ;;
  activate)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    activate_stage
    ;;
  immediate)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    stage_sni "$2"
    activate_stage
    ;;
esac

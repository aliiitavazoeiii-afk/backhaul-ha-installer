#!/usr/bin/env bash
set -Eeuo pipefail

APP=maya-failover
ETC=/etc/$APP
STATE=/var/lib/$APP
CTRL=/opt/$APP/controller.py
CFG=$ETC/config.json
SECRETS=$ETC/secrets.env
VLESS=$ETC/vless.env
SCHEDULE_CFG=$ETC/shared-schedule.json

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -r "$CFG" && -r "$SECRETS" && -r "$VLESS" && -x "$CTRL" ]] || {
  echo "Existing Maya VLESS failover controller is required first." >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y jq curl python3 util-linux >/dev/null

mkdir -p "$STATE/backups"
chmod 0700 "$ETC" "$STATE" "$STATE/backups"

MAYA1_BASE="$(jq -r '.services.maya1.main_iran_ip // empty' "$CFG")"
MAYA3_BASE="$(jq -r '.services.maya3.main_iran_ip // empty' "$CFG")"
[[ -n "$MAYA1_BASE" && -n "$MAYA3_BASE" ]] || { echo "Missing current Maya main mappings." >&2; exit 1; }

cat >"$SCHEDULE_CFG" <<EOF
{
  "timezone": "Asia/Tehran",
  "shared_iran_ip": "5.10.249.206",
  "maya1_baseline_main": "${MAYA1_BASE}",
  "maya3_baseline_main": "${MAYA3_BASE}",
  "maya3_shared_start": "12:00",
  "maya3_drain_start": "17:30",
  "maya1_shared_start": "18:00",
  "baseline_start": "00:00",
  "drain_minutes": 30
}
EOF
chmod 0600 "$SCHEDULE_CFG"

cat > /usr/local/bin/maya-shared-schedule <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
APP=maya-failover
ETC=/etc/$APP
STATE=/var/lib/$APP
CFG=$ETC/config.json
SECRETS=$ETC/secrets.env
VLESS=$ETC/vless.env
CTRL=/opt/$APP/controller.py
SCHEDULE_CFG=$ETC/shared-schedule.json
SCHEDULE_STATE=$STATE/shared-schedule-state
SERVICE=$APP.service
LOCK=/run/maya-shared-schedule.lock

log(){ echo "$(date -Is) $*"; }
load_secret(){ local k="$1"; awk -F= -v key="$k" '$1==key {sub(/^[^=]*=/,""); print; exit}' "$SECRETS"; }

probe(){
  local service="$1" ip="$2"
  python3 - "$service" "$ip" "$CTRL" "$VLESS" <<'PY'
import importlib.util, sys
from pathlib import Path
service, ip, ctrl_path, vless_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("maya_controller", ctrl_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
env = mod.load_env(Path(vless_path))
key = "MAYA1_VLESS" if service == "maya1" else "MAYA3_VLESS"
creds = mod.parse_vless(env[key])
ok, detail = mod.vless_probe(creds, ip)
print(("OK" if ok else "FAIL") + " — " + detail)
raise SystemExit(0 if ok else 1)
PY
}

cf_ip(){
  local service="$1" zone record token
  zone="$(jq -r '.cloudflare.zone_id' "$CFG")"
  record="$(jq -r ".services.${service}.record_id" "$CFG")"
  token="$(load_secret CLOUDFLARE_API_TOKEN)"
  curl -fsS -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$record" | jq -r '.result.content // empty'
}

cf_set(){
  local service="$1" ip="$2" zone record token ttl out
  zone="$(jq -r '.cloudflare.zone_id' "$CFG")"
  record="$(jq -r ".services.${service}.record_id" "$CFG")"
  ttl="$(jq -r '.cloudflare.ttl // 60' "$CFG")"
  token="$(load_secret CLOUDFLARE_API_TOKEN)"
  out="$(curl -fsS -X PATCH -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data "{\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":false}" \
    "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$record")"
  [[ "$(jq -r '.success // false' <<<"$out")" == true ]] || return 1
}

notify(){
  local text="$1" token chat
  token="$(load_secret TELEGRAM_BOT_TOKEN)"; chat="$(load_secret TELEGRAM_CHAT_ID)"
  [[ -n "$token" && -n "$chat" ]] || return 0
  curl -fsS --max-time 8 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" >/dev/null 2>&1 || true
}

set_main_mapping(){
  local service="$1" ip="$2" tmp
  tmp="$(mktemp)"
  jq --arg s "$service" --arg ip "$ip" '.services[$s].main_iran_ip = $ip' "$CFG" >"$tmp"
  install -m 0600 "$tmp" "$CFG"
  rm -f "$tmp"
}

reset_state(){
  local offset=0
  [[ -r "$STATE/state.json" ]] && offset="$(jq -r '.telegram_offset // 0' "$STATE/state.json" 2>/dev/null || echo 0)"
  cat >"$STATE/state.json" <<EOF
{"services":{},"telegram_offset":${offset}}
EOF
  chmod 0600 "$STATE/state.json"
}

restore_target(){
  local service="$1" base_ip="$2" spare_ip
  spare_ip="$(jq -r ".services.${service}.spare_iran_ip // empty" "$CFG")"
  if probe "$service" "$base_ip" >/dev/null 2>&1; then echo "$base_ip"; return 0; fi
  if [[ -n "$spare_ip" ]] && probe "$service" "$spare_ip" >/dev/null 2>&1; then echo "$spare_ip"; return 0; fi
  return 1
}

phase_now(){
  local h m minute
  h="$(TZ=Asia/Tehran date +%H)"
  m="$(TZ=Asia/Tehran date +%M)"
  minute=$((10#$h * 60 + 10#$m))
  if (( minute >= 720 && minute < 1050 )); then
    echo maya3_shared
  elif (( minute >= 1050 && minute < 1080 )); then
    echo maya3_drain
  elif (( minute >= 1080 )); then
    echo maya1_shared
  else
    echo baseline
  fi
}

apply_phase(){
  local phase="$1" shared m1base m3base old1 old3 target1 target3 backup was_active=0
  shared="$(jq -r '.shared_iran_ip' "$SCHEDULE_CFG")"
  m1base="$(jq -r '.maya1_baseline_main' "$SCHEDULE_CFG")"
  m3base="$(jq -r '.maya3_baseline_main' "$SCHEDULE_CFG")"
  old1="$(cf_ip maya1)"; old3="$(cf_ip maya3)"
  [[ -n "$old1" && -n "$old3" ]] || { log "Could not read Cloudflare DNS."; return 1; }

  case "$phase" in
    maya3_shared)
      log "Preflight MAYA3 shared path $shared"
      probe maya3 "$shared" || { notify "⛔ MAYA3 scheduled Shared Hub switch blocked: VLESS probe failed on $shared"; return 1; }
      target1="$(restore_target maya1 "$m1base")" || { notify "⛔ MAYA1 has no healthy original path; scheduled transition aborted."; return 1; }
      target3="$shared"
      ;;
    maya3_drain)
      # DNS moves away 30 minutes before the 18:00 slot handoff, while the
      # Iran Shared Hub itself keeps serving MAYA3 until 18:00. Existing TCP
      # sessions are untouched and clients with a stale DNS cache can still
      # reconnect to the old shared IP during the drain window.
      target1="$(restore_target maya1 "$m1base")" || { notify "⛔ MAYA1 has no healthy original path; MAYA3 drain aborted."; return 1; }
      target3="$(restore_target maya3 "$m3base")" || { notify "⛔ MAYA3 has no healthy original path; drain aborted."; return 1; }
      log "MAYA3 drain: DNS -> $target3 while Shared Hub remains on MAYA3 until 18:00"
      ;;
    maya1_shared)
      log "Preflight MAYA1 shared path $shared"
      probe maya1 "$shared" || { notify "⛔ MAYA1 scheduled Shared Hub switch blocked: VLESS probe failed on $shared"; return 1; }
      target3="$(restore_target maya3 "$m3base")" || { notify "⛔ MAYA3 has no healthy original path; scheduled transition aborted."; return 1; }
      target1="$shared"
      ;;
    baseline)
      target1="$(restore_target maya1 "$m1base")" || { notify "⛔ MAYA1 has no healthy original path at schedule restore."; return 1; }
      target3="$(restore_target maya3 "$m3base")" || { notify "⛔ MAYA3 has no healthy original path at schedule restore."; return 1; }
      ;;
    *) return 2 ;;
  esac

  backup="$STATE/backups/pre-shared-schedule-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$backup" "$CFG" "$STATE/state.json" 2>/dev/null || tar -czf "$backup" "$CFG"
  chmod 0600 "$backup"
  systemctl is-active --quiet "$SERVICE" && was_active=1
  systemctl stop "$SERVICE" 2>/dev/null || true

  rollback(){
    log "Rolling back schedule transition"
    tar -xzf "$backup" -C /
    cf_set maya1 "$old1" || true
    cf_set maya3 "$old3" || true
    [[ $was_active -eq 1 ]] && systemctl start "$SERVICE" 2>/dev/null || true
  }

  # Restore canonical main mappings first; only an actively shared service
  # gets the shared IP as its main mapping. Drain uses the original main.
  set_main_mapping maya1 "$m1base"
  set_main_mapping maya3 "$m3base"
  [[ "$phase" == maya1_shared ]] && set_main_mapping maya1 "$shared"
  [[ "$phase" == maya3_shared ]] && set_main_mapping maya3 "$shared"

  cf_set maya1 "$target1" || { rollback; return 1; }
  cf_set maya3 "$target3" || { rollback; return 1; }
  reset_state
  systemctl start "$SERVICE" || { rollback; return 1; }
  sleep 2
  systemctl is-active --quiet "$SERVICE" || { rollback; return 1; }

  printf '%s\n' "$phase" >"$SCHEDULE_STATE"
  chmod 0600 "$SCHEDULE_STATE"
  notify "🕒 Maya schedule applied: ${phase}\nMAYA1 -> ${target1}\nMAYA3 -> ${target3}"
  log "Applied $phase: MAYA1=$target1 MAYA3=$target3"
}

status(){
  echo "desired=$(phase_now)"
  echo "applied=$(cat "$SCHEDULE_STATE" 2>/dev/null || echo none)"
  echo "MAYA1 DNS=$(cf_ip maya1) main=$(jq -r '.services.maya1.main_iran_ip' "$CFG")"
  echo "MAYA3 DNS=$(cf_ip maya3) main=$(jq -r '.services.maya3.main_iran_ip' "$CFG")"
  cat "$SCHEDULE_CFG"
}

exec 9>"$LOCK"
flock -n 9 || exit 0
case "${1:-reconcile}" in
  reconcile)
    desired="$(phase_now)"; applied="$(cat "$SCHEDULE_STATE" 2>/dev/null || echo none)"
    [[ "$desired" == "$applied" ]] && exit 0
    apply_phase "$desired"
    ;;
  force)
    [[ ${2:-} =~ ^(baseline|maya1_shared|maya3_shared|maya3_drain)$ ]] || { echo "force requires baseline|maya1_shared|maya3_shared|maya3_drain" >&2; exit 2; }
    apply_phase "$2"
    ;;
  status) status ;;
  reset-phase) rm -f "$SCHEDULE_STATE" ;;
  *) echo "Usage: maya-shared-schedule {reconcile|status|force PHASE|reset-phase}"; exit 2 ;;
esac
SCRIPT
chmod 0755 /usr/local/bin/maya-shared-schedule

cat >/etc/systemd/system/maya-shared-schedule.service <<EOF
[Unit]
Description=Maya scheduled shared FRP/DNS reconciler
After=network-online.target maya-failover.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/maya-shared-schedule reconcile
EOF

cat >/etc/systemd/system/maya-shared-schedule.timer <<EOF
[Unit]
Description=Maya schedule with 17:30 MAYA3 drain before 18:00 handoff
[Timer]
OnBootSec=20s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true
Unit=maya-shared-schedule.service
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now maya-shared-schedule.timer >/dev/null
/usr/local/bin/maya-shared-schedule reconcile || true

echo
echo "Installed Maya Shared schedule (Asia/Tehran):"
echo "  00:00-12:00  original healthy paths"
echo "  12:00-17:30  MAYA3 -> 5.10.249.206"
echo "  17:30-18:00  MAYA3 DNS drains to original path; existing Shared sessions stay alive"
echo "  18:00-24:00  MAYA1 -> 5.10.249.206"
echo
echo "Status: maya-shared-schedule status"
echo "Manual: maya-shared-schedule force maya3_shared"
echo "        maya-shared-schedule force maya3_drain"
echo "        maya-shared-schedule force maya1_shared"
echo "        maya-shared-schedule force baseline"

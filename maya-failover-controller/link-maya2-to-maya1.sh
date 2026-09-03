#!/usr/bin/env bash
set -Eeuo pipefail

APP="maya-failover"
ETC="/etc/${APP}"
STATE="/var/lib/${APP}"
CTRL="/opt/${APP}/controller.py"
CFG="${ETC}/config.json"
SECRETS="${ETC}/secrets.env"
SCHED="/usr/local/bin/maya-shared-schedule"
SERVICE="${APP}.service"
MAYA2_DOMAIN="${1:-maya2.biya2film.top}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
for f in "$CTRL" "$CFG" "$SECRETS"; do
  [[ -r "$f" ]] || { echo "Missing required file: $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }

# v1 could leave controller.py syntactically broken before restarting the service.
# If that happened, restore the newest automatic pre-link backup first.
if ! python3 -m py_compile "$CTRL" >/dev/null 2>&1; then
  LATEST_BACKUP="$(find "$STATE/backups" -maxdepth 1 -type d -name 'maya12-link-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print}')"
  [[ -n "$LATEST_BACKUP" && -f "$LATEST_BACKUP/controller.py" && -f "$LATEST_BACKUP/config.json" ]] || {
    echo "controller.py is broken and no Maya12 backup was found." >&2
    exit 1
  }
  echo "[i] Restoring controller from: $LATEST_BACKUP"
  cp -a "$LATEST_BACKUP/controller.py" "$CTRL"
  cp -a "$LATEST_BACKUP/config.json" "$CFG"
  if [[ -f "$LATEST_BACKUP/maya-shared-schedule" ]]; then
    cp -a "$LATEST_BACKUP/maya-shared-schedule" "$SCHED"
  fi
  python3 -m py_compile "$CTRL"
  [[ ! -f "$SCHED" ]] || bash -n "$SCHED"
fi

load_secret(){
  local k="$1"
  awk -F= -v key="$k" '$1==key {sub(/^[^=]*=/,""); print; exit}' "$SECRETS"
}

ZONE_ID="$(jq -r '.cloudflare.zone_id // empty' "$CFG")"
TOKEN="$(load_secret CLOUDFLARE_API_TOKEN)"
MAYA1_RECORD="$(jq -r '.services.maya1.record_id // empty' "$CFG")"
[[ -n "$ZONE_ID" && -n "$TOKEN" && -n "$MAYA1_RECORD" ]] || {
  echo "Missing Cloudflare zone/token or Maya1 record_id." >&2
  exit 1
}

cf_get_by_id(){
  local rid="$1"
  curl -fsS -H "Authorization: Bearer $TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${rid}"
}

cf_set_by_id(){
  local rid="$1" ip="$2" ttl
  ttl="$(jq -r '.cloudflare.ttl // 60' "$CFG")"
  curl -fsS -X PATCH \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"content\":\"${ip}\",\"ttl\":${ttl},\"proxied\":false}" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${rid}"
}

LOOKUP="$(curl -fsS -G -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "name=${MAYA2_DOMAIN}" \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records")"
[[ "$(jq -r '.success // false' <<<"$LOOKUP")" == true ]] || {
  echo "Cloudflare lookup for ${MAYA2_DOMAIN} failed." >&2
  exit 1
}
COUNT="$(jq -r '.result | length' <<<"$LOOKUP")"
[[ "$COUNT" == "1" ]] || {
  echo "Expected exactly one DNS record for ${MAYA2_DOMAIN}; found ${COUNT}." >&2
  exit 1
}
MAYA2_RECORD="$(jq -r '.result[0].id' <<<"$LOOKUP")"
MAYA2_TYPE="$(jq -r '.result[0].type' <<<"$LOOKUP")"
[[ "$MAYA2_TYPE" == "A" ]] || {
  echo "${MAYA2_DOMAIN} must currently be an A record; found ${MAYA2_TYPE}." >&2
  exit 1
}
[[ "$MAYA2_RECORD" != "$MAYA1_RECORD" ]] || {
  echo "Maya1 and Maya2 unexpectedly use the same Cloudflare record id." >&2
  exit 1
}

MAYA1_INFO="$(cf_get_by_id "$MAYA1_RECORD")"
MAYA2_INFO="$(cf_get_by_id "$MAYA2_RECORD")"
[[ "$(jq -r '.success // false' <<<"$MAYA1_INFO")" == true && "$(jq -r '.success // false' <<<"$MAYA2_INFO")" == true ]] || {
  echo "Could not read current Maya1/Maya2 records." >&2
  exit 1
}
MAYA1_IP="$(jq -r '.result.content' <<<"$MAYA1_INFO")"
MAYA2_OLD_IP="$(jq -r '.result.content' <<<"$MAYA2_INFO")"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="${STATE}/backups/maya12-link-${TS}"
mkdir -p "$BACKUP"
chmod 0700 "$BACKUP"
cp -a "$CTRL" "$BACKUP/controller.py"
cp -a "$CFG" "$BACKUP/config.json"
[[ -f "$SCHED" ]] && cp -a "$SCHED" "$BACKUP/maya-shared-schedule" || true

rollback_files(){
  cp -a "$BACKUP/controller.py" "$CTRL"
  cp -a "$BACKUP/config.json" "$CFG"
  [[ -f "$BACKUP/maya-shared-schedule" ]] && cp -a "$BACKUP/maya-shared-schedule" "$SCHED" || true
}

TMP="$(mktemp)"
jq --arg domain "$MAYA2_DOMAIN" --arg rid "$MAYA2_RECORD" '
  .services.maya1.linked_records =
    (((.services.maya1.linked_records // []) + [{domain:$domain, record_id:$rid}]) | unique_by(.record_id))
' "$CFG" >"$TMP"
install -m 0600 "$TMP" "$CFG"
rm -f "$TMP"

python3 - "$CTRL" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
marker = "# MAYA12_LINKED_DNS_V2"

if marker not in s:
    start_sig = "def switch_to(cfg, secrets, name, svc, state, target, reason):"
    end_sig = "\ndef refresh_dns_modes(cfg, secrets, state):"
    start = s.find(start_sig)
    end = s.find(end_sig, start)
    if start < 0 or end < 0:
        raise SystemExit("Could not locate switch_to safely; controller layout is unexpected.")

    new_switch = r'''def switch_to(cfg, secrets, name, svc, state, target, reason):
    # MAYA12_LINKED_DNS_V2
    ip = svc[f"{target}_iran_ip"]
    zone_id = cfg["cloudflare"]["zone_id"]
    ttl = cfg["cloudflare"].get("ttl", 60)
    targets = [(svc["record_id"], svc.get("domain", name))]
    if name == "maya1":
        for linked in svc.get("linked_records", []):
            rid = linked.get("record_id")
            if rid:
                targets.append((rid, linked.get("domain", "maya2")))

    before = {}
    changed = []
    results = []
    for rid, domain in targets:
        before[rid] = cf_record(secrets, zone_id, rid)

    try:
        for rid, domain in targets:
            rec = cf_switch(secrets, zone_id, rid, ip, ttl)
            changed.append(rid)
            results.append((domain, rec))
    except Exception:
        for rid in reversed(changed):
            try:
                cf_switch(secrets, zone_id, rid, before[rid]["content"], ttl)
            except Exception as rb_err:
                log(f"DNS rollback failed for {rid}: {rb_err}")
        raise

    rec = results[0][1]
    st = state["services"][name]
    st["mode"] = target
    st["last_dns_ip"] = rec["content"]
    st["active_failures"] = 0
    st["blocked_alerted"] = False
    st["last_switch_at"] = now_iso()
    atomic_json(STATE_PATH, state)

    mirror_text = ""
    if len(results) > 1:
        mirror_text = "\nMirrors: " + ", ".join(
            f"{domain} -> {item['content']}" for domain, item in results[1:]
        )
    send_tg(
        secrets,
        f"🔁 {name.upper()} AUTO SWITCH\n"
        f"{svc['domain']}\n"
        f"→ {target.upper()} {ip}\n"
        f"Reason: {reason}\n"
        f"Cloudflare update: OK{mirror_text}"
    )
'''
    s = s[:start] + new_switch.rstrip() + "\n\n" + s[end + 1:]

    anchor = '''        rec = cf_record(secrets, cfg["cloudflare"]["zone_id"], svc["record_id"])
        ip = rec["content"]
        mode = service_mode(svc, ip)'''
    insert = '''        rec = cf_record(secrets, cfg["cloudflare"]["zone_id"], svc["record_id"])
        ip = rec["content"]
        if name == "maya1":
            for linked in svc.get("linked_records", []):
                rid = linked.get("record_id")
                if not rid:
                    continue
                try:
                    lrec = cf_record(secrets, cfg["cloudflare"]["zone_id"], rid)
                    if lrec.get("content") != ip:
                        cf_switch(
                            secrets,
                            cfg["cloudflare"]["zone_id"],
                            rid,
                            ip,
                            cfg["cloudflare"].get("ttl", 60),
                        )
                        log(f"MAYA1 mirror resynced: {linked.get('domain','maya2')} -> {ip}")
                except Exception as e:
                    log(f"MAYA1 mirror sync failed for {linked.get('domain','maya2')}: {e}")
        mode = service_mode(svc, ip)'''
    if anchor not in s:
        raise SystemExit("Could not locate refresh_dns_modes anchor safely.")
    s = s.replace(anchor, insert, 1)
    p.write_text(s, encoding="utf-8")
PY

if [[ -f "$SCHED" ]]; then
python3 - "$SCHED" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
marker = "# MAYA12_LINKED_DNS_V2"
if marker not in s:
    start_sig = "cf_set(){"
    end_sig = "\n\nnotify(){"
    start = s.find(start_sig)
    end = s.find(end_sig, start)
    if start < 0 or end < 0:
        raise SystemExit("Could not locate scheduler cf_set safely.")

    new_cf_set = r'''cf_set(){
  # MAYA12_LINKED_DNS_V2
  local service="$1" ip="$2" zone record token ttl out rid old
  local -a targets changed
  targets=()
  changed=()
  zone="$(jq -r '.cloudflare.zone_id' "$CFG")"
  record="$(jq -r ".services.${service}.record_id" "$CFG")"
  ttl="$(jq -r '.cloudflare.ttl // 60' "$CFG")"
  token="$(load_secret CLOUDFLARE_API_TOKEN)"
  targets+=("$record")
  if [[ "$service" == "maya1" ]]; then
    while IFS= read -r rid; do
      [[ -n "$rid" ]] && targets+=("$rid")
    done < <(jq -r '.services.maya1.linked_records[]?.record_id // empty' "$CFG")
  fi

  declare -A before=()
  for rid in "${targets[@]}"; do
    old="$(curl -fsS -H "Authorization: Bearer $token" \
      "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$rid" | jq -r '.result.content // empty')"
    [[ -n "$old" ]] || return 1
    before["$rid"]="$old"
  done

  for rid in "${targets[@]}"; do
    out="$(curl -fsS -X PATCH \
      -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' \
      --data "{\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":false}" \
      "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$rid")" || out=''
    if [[ "$(jq -r '.success // false' <<<"$out" 2>/dev/null)" != true ]]; then
      for rid in "${changed[@]}"; do
        curl -fsS -X PATCH \
          -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' \
          --data "{\"content\":\"${before[$rid]}\",\"ttl\":$ttl,\"proxied\":false}" \
          "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$rid" >/dev/null 2>&1 || true
      done
      return 1
    fi
    changed+=("$rid")
  done
}'''
    s = s[:start] + new_cf_set.rstrip() + "\n\n" + s[end + 2:]
    p.write_text(s, encoding="utf-8")
PY
fi

if ! python3 -m py_compile "$CTRL"; then
  rollback_files
  echo "Controller syntax validation failed; files rolled back." >&2
  exit 1
fi
if [[ -f "$SCHED" ]] && ! bash -n "$SCHED"; then
  rollback_files
  echo "Scheduler syntax validation failed; files rolled back." >&2
  exit 1
fi

# Initial alignment: Maya2 follows the CURRENT Maya1 DNS before controller reload.
ALIGN="$(cf_set_by_id "$MAYA2_RECORD" "$MAYA1_IP")"
if [[ "$(jq -r '.success // false' <<<"$ALIGN")" != true ]]; then
  rollback_files
  echo "Initial Maya2 DNS alignment failed; files rolled back." >&2
  exit 1
fi

if systemctl is-active --quiet "$SERVICE"; then
  systemctl restart "$SERVICE"
  sleep 2
  if ! systemctl is-active --quiet "$SERVICE"; then
    rollback_files
    cf_set_by_id "$MAYA2_RECORD" "$MAYA2_OLD_IP" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE" || true
    echo "Controller did not recover; rollback applied." >&2
    exit 1
  fi
fi

M1_NOW="$(jq -r '.result.content' <<<"$(cf_get_by_id "$MAYA1_RECORD")")"
M2_NOW="$(jq -r '.result.content' <<<"$(cf_get_by_id "$MAYA2_RECORD")")"

echo
echo "Maya1/Maya2 linked DNS enabled."
echo "Maya1: ${M1_NOW}"
echo "Maya2: ${M2_NOW}"
if [[ "$M1_NOW" == "$M2_NOW" ]]; then
  echo "SYNC: OK"
else
  echo "SYNC: FAILED" >&2
  exit 1
fi
echo "Backup: ${BACKUP}"

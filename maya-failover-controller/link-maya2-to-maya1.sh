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

TMP="$(mktemp)"
jq --arg domain "$MAYA2_DOMAIN" --arg rid "$MAYA2_RECORD" '
  .services.maya1.linked_records =
    (((.services.maya1.linked_records // []) + [{domain:$domain, record_id:$rid}]) | unique_by(.record_id))
' "$CFG" >"$TMP"
install -m 0600 "$TMP" "$CFG"
rm -f "$TMP"

python3 - "$CTRL" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
marker='# MAYA12_LINKED_DNS_V1'
if marker not in s:
    pat=r'def switch_to\(cfg, secrets, name, svc, state, target, reason\):\n.*?\n\ndef refresh_dns_modes\(cfg, secrets, state\):'
    repl='''def switch_to(cfg, secrets, name, svc, state, target, reason):\n    # MAYA12_LINKED_DNS_V1\n    ip = svc[f"{target}_iran_ip"]\n    zone_id = cfg["cloudflare"]["zone_id"]\n    ttl = cfg["cloudflare"].get("ttl", 60)\n    targets = [(svc["record_id"], svc.get("domain", name))]\n    if name == "maya1":\n        for linked in svc.get("linked_records", []):\n            rid = linked.get("record_id")\n            if rid:\n                targets.append((rid, linked.get("domain", "maya2")))\n\n    before = {}\n    changed = []\n    results = []\n    for rid, domain in targets:\n        before[rid] = cf_record(secrets, zone_id, rid)\n\n    try:\n        for rid, domain in targets:\n            rec = cf_switch(secrets, zone_id, rid, ip, ttl)\n            changed.append(rid)\n            results.append((domain, rec))\n    except Exception:\n        for rid in reversed(changed):\n            try:\n                cf_switch(secrets, zone_id, rid, before[rid]["content"], ttl)\n            except Exception as rb_err:\n                log(f"DNS rollback failed for {rid}: {rb_err}")\n        raise\n\n    rec = results[0][1]\n    st = state["services"][name]\n    st["mode"] = target\n    st["last_dns_ip"] = rec["content"]\n    st["active_failures"] = 0\n    st["blocked_alerted"] = False\n    st["last_switch_at"] = now_iso()\n    atomic_json(STATE_PATH, state)\n    mirror_text = ""\n    if len(results) > 1:\n        mirror_text = "\\nMirrors: " + ", ".join(f"{domain} -> {r['content']}" for domain, r in results[1:])\n    send_tg(\n        secrets,\n        f"🔁 {name.upper()} AUTO SWITCH\\n"\n        f"{svc['domain']}\\n"\n        f"→ {target.upper()} {ip}\\n"\n        f"Reason: {reason}\\n"\n        f"Cloudflare update: OK{mirror_text}"\n    )\n\n\ndef refresh_dns_modes(cfg, secrets, state):'''
    ns,n=re.subn(pat,repl,s,flags=re.S)
    if n != 1:
        raise SystemExit('Could not patch switch_to safely; controller layout is unexpected.')
    s=ns

    anchor='''        rec = cf_record(secrets, cfg["cloudflare"]["zone_id"], svc["record_id"])\n        ip = rec["content"]\n        mode = service_mode(svc, ip)'''
    insert='''        rec = cf_record(secrets, cfg["cloudflare"]["zone_id"], svc["record_id"])\n        ip = rec["content"]\n        if name == "maya1":\n            for linked in svc.get("linked_records", []):\n                rid = linked.get("record_id")\n                if not rid:\n                    continue\n                try:\n                    lrec = cf_record(secrets, cfg["cloudflare"]["zone_id"], rid)\n                    if lrec.get("content") != ip:\n                        cf_switch(secrets, cfg["cloudflare"]["zone_id"], rid, ip, cfg["cloudflare"].get("ttl", 60))\n                        log(f"MAYA1 mirror resynced: {linked.get('domain','maya2')} -> {ip}")\n                except Exception as e:\n                    log(f"MAYA1 mirror sync failed for {linked.get('domain','maya2')}: {e}")\n        mode = service_mode(svc, ip)'''
    if anchor not in s:
        raise SystemExit('Could not patch refresh_dns_modes safely; controller layout is unexpected.')
    s=s.replace(anchor,insert,1)
    p.write_text(s,encoding='utf-8')
PY

if [[ -f "$SCHED" ]]; then
python3 - "$SCHED" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
marker='# MAYA12_LINKED_DNS_V1'
if marker not in s:
    pat=r'cf_set\(\)\{\n.*?\n\}\n\nnotify\(\)\{'
    repl='''cf_set(){\n  # MAYA12_LINKED_DNS_V1\n  local service="$1" ip="$2" zone record token ttl out rid old changed=()\n  zone="$(jq -r '.cloudflare.zone_id' "$CFG")"\n  record="$(jq -r ".services.${service}.record_id" "$CFG")"\n  ttl="$(jq -r '.cloudflare.ttl // 60' "$CFG")"\n  token="$(load_secret CLOUDFLARE_API_TOKEN)"\n  local targets=("$record")\n  if [[ "$service" == "maya1" ]]; then\n    while IFS= read -r rid; do [[ -n "$rid" ]] && targets+=("$rid"); done < <(jq -r '.services.maya1.linked_records[]?.record_id // empty' "$CFG")\n  fi\n  declare -A before=()\n  for rid in "${targets[@]}"; do\n    old="$(curl -fsS -H "Authorization: Bearer $token" "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$rid" | jq -r '.result.content // empty')"\n    [[ -n "$old" ]] || return 1\n    before["$rid"]="$old"\n  done\n  for rid in "${targets[@]}"; do\n    out="$(curl -fsS -X PATCH -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \\\n      --data "{\\"content\\":\\"$ip\\",\\"ttl\\":$ttl,\\"proxied\\":false}" \\\n      "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$rid")" || out=''\n    if [[ "$(jq -r '.success // false' <<<"$out" 2>/dev/null)" != true ]]; then\n      for rid in "${changed[@]}"; do\n        curl -fsS -X PATCH -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \\\n          --data "{\\"content\\":\\"${before[$rid]}\\",\\"ttl\\":$ttl,\\"proxied\\":false}" \\\n          "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$rid" >/dev/null 2>&1 || true\n      done\n      return 1\n    fi\n    changed+=("$rid")\n  done\n}\n\nnotify(){'''
    ns,n=re.subn(pat,repl,s,flags=re.S)
    if n != 1:
        raise SystemExit('Could not patch scheduler cf_set safely; layout is unexpected.')
    p.write_text(ns,encoding='utf-8')
PY
fi

python3 -m py_compile "$CTRL"
[[ ! -f "$SCHED" ]] || bash -n "$SCHED"

# Initial alignment: Maya2 follows the CURRENT Maya1 DNS before the service resumes.
ALIGN="$(cf_set_by_id "$MAYA2_RECORD" "$MAYA1_IP")"
if [[ "$(jq -r '.success // false' <<<"$ALIGN")" != true ]]; then
  cp -a "$BACKUP/controller.py" "$CTRL"
  cp -a "$BACKUP/config.json" "$CFG"
  [[ -f "$BACKUP/maya-shared-schedule" ]] && cp -a "$BACKUP/maya-shared-schedule" "$SCHED" || true
  echo "Initial Maya2 DNS alignment failed; files rolled back." >&2
  exit 1
fi

if systemctl is-active --quiet "$SERVICE"; then
  systemctl restart "$SERVICE"
  sleep 2
  systemctl is-active --quiet "$SERVICE" || {
    cp -a "$BACKUP/controller.py" "$CTRL"
    cp -a "$BACKUP/config.json" "$CFG"
    [[ -f "$BACKUP/maya-shared-schedule" ]] && cp -a "$BACKUP/maya-shared-schedule" "$SCHED" || true
    cf_set_by_id "$MAYA2_RECORD" "$MAYA2_OLD_IP" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE" || true
    echo "Controller did not recover; rollback applied." >&2
    exit 1
  }
fi

M1_NOW="$(jq -r '.result.content' <<<"$(cf_get_by_id "$MAYA1_RECORD")")"
M2_NOW="$(jq -r '.result.content' <<<"$(cf_get_by_id "$MAYA2_RECORD")")"

echo
echo "Maya1/Maya2 linked DNS enabled."
echo "Maya1: ${MAYA1_IP}"
echo "Maya2: ${M2_NOW}"
if [[ "$M1_NOW" == "$M2_NOW" ]]; then
  echo "SYNC: OK"
else
  echo "SYNC: FAILED" >&2
  exit 1
fi
echo "Backup: ${BACKUP}"

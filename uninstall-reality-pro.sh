#!/usr/bin/env bash
set -Eeuo pipefail
DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
STATE_DIR="/var/lib/reality-pro"
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STATE_DIR/backups"
chmod 700 "$STATE_DIR" "$STATE_DIR/backups" 2>/dev/null || true
if [[ -f "$DB_PATH" ]]; then
  sqlite3 "$DB_PATH" ".backup '$STATE_DIR/backups/x-ui-before-uninstall-$STAMP.db'"
  python3 - "$DB_PATH" <<'PY'
import copy,json,sqlite3,sys
p=sys.argv[1]
con=sqlite3.connect(p,timeout=20)
row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
if row:
    raw=row[0]; obj=json.loads(raw)
    for _ in range(8):
        if isinstance(obj,dict) and 'xraySetting' in obj and isinstance(obj['xraySetting'],(dict,str)):
            obj=obj['xraySetting']
            if isinstance(obj,str): obj=json.loads(obj)
        else: break
    if isinstance(obj,dict):
        obj['outbounds']=[o for o in (obj.get('outbounds') or []) if not (isinstance(o,dict) and o.get('tag') in {'reality-pro-home-f1','reality-pro-home-f2'})]
        rt=obj.setdefault('routing',{})
        rt['rules']=[r for r in (rt.get('rules') or []) if not (isinstance(r,dict) and (str(r.get('ruleTag') or '').startswith('reality-pro:') or r.get('outboundTag') in {'reality-pro-home-f1','reality-pro-home-f2'}))]
        con.execute('BEGIN IMMEDIATE')
        con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",(json.dumps(obj,separators=(',',':')),))
        con.commit()
con.close()
PY
  if systemctl cat x-ui.service >/dev/null 2>&1; then systemctl restart x-ui; fi
fi
systemctl disable --now reality-pro-controller.service reality-pro-fabric.service 2>/dev/null || true
rm -f /etc/systemd/system/reality-pro-controller.service /etc/systemd/system/reality-pro-fabric.service
systemctl daemon-reload
rm -f /usr/local/bin/reality-pro
rm -rf /opt/reality-pro /etc/reality-pro
cat <<EOF
Reality Pro removed.
x-ui backup: $STATE_DIR/backups/x-ui-before-uninstall-$STAMP.db
State/backups were preserved under: $STATE_DIR
EOF

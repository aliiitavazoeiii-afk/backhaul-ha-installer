#!/usr/bin/env bash
set -Eeuo pipefail

DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
RUNTIME_CONFIG="${XUI_RUNTIME_CONFIG:-/usr/local/x-ui/bin/config.json}"
BACKUP_DIR="/var/lib/xhttp-dual/backups"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { apt-get update && apt-get install -y sqlite3; }
command -v python3 >/dev/null 2>&1 || { apt-get update && apt-get install -y python3; }
[[ -f "$DB_PATH" ]] || { echo "Missing x-ui DB: $DB_PATH"; exit 1; }

if sqlite3 "$DB_PATH" "SELECT 1 FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;" | grep -qx 1; then
  echo "xrayTemplateConfig already exists. Nothing to bootstrap."
  exit 0
fi

[[ -f "$RUNTIME_CONFIG" ]] || {
  echo "xrayTemplateConfig is missing and runtime config was not found: $RUNTIME_CONFIG"
  echo "Set XUI_RUNTIME_CONFIG=/path/to/config.json and rerun."
  exit 1
}

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR" 2>/dev/null || true
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_DIR/x-ui-before-template-bootstrap-$STAMP.db"
cp -a "$DB_PATH" "$BACKUP"
chmod 600 "$BACKUP" 2>/dev/null || true

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

python3 - "$DB_PATH" "$RUNTIME_CONFIG" "$TMP" <<'PY'
import json, sqlite3, sys

db_path, runtime_path, out_path = sys.argv[1:]
with open(runtime_path, 'r', encoding='utf-8') as f:
    cfg = json.load(f)

con = sqlite3.connect(db_path)
try:
    tags = {str(r[0]).strip() for r in con.execute("SELECT tag FROM inbounds WHERE tag IS NOT NULL AND trim(tag) <> ''")}
finally:
    con.close()

inbounds = cfg.get('inbounds') or []
clean = []
removed = []
for inbound in inbounds:
    if isinstance(inbound, dict) and str(inbound.get('tag') or '').strip() in tags:
        removed.append(str(inbound.get('tag')))
        continue
    clean.append(inbound)
cfg['inbounds'] = clean

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, separators=(',', ':'))

print('Removed DB-generated inbound tags from template:', ', '.join(sorted(set(removed))) or '(none)')
PY

python3 -m json.tool "$TMP" >/dev/null
VALUE="$(cat "$TMP")"

sqlite3 "$DB_PATH" <<SQL
BEGIN IMMEDIATE;
INSERT INTO settings(key,value) VALUES('xrayTemplateConfig',$(printf "%q" "$VALUE"));
COMMIT;
SQL

# The shell %q form is not SQL-safe on every sqlite build; verify and fall back via Python if needed.
if ! sqlite3 "$DB_PATH" "SELECT 1 FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;" | grep -qx 1; then
  cp -a "$BACKUP" "$DB_PATH"
  python3 - "$DB_PATH" "$TMP" <<'PY'
import sqlite3, sys
p, f = sys.argv[1:]
value = open(f, 'r', encoding='utf-8').read()
con = sqlite3.connect(p)
try:
    con.execute('BEGIN IMMEDIATE')
    con.execute("INSERT INTO settings(key,value) VALUES(?,?)", ('xrayTemplateConfig', value))
    con.commit()
finally:
    con.close()
PY
fi

python3 - "$DB_PATH" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
con.close()
if not row:
    raise SystemExit('bootstrap failed: row missing')
obj = json.loads(row[0])
if not isinstance(obj, dict):
    raise SystemExit('bootstrap failed: template is not object')
print('xrayTemplateConfig bootstrap OK')
PY

echo "Backup: $BACKUP"

#!/usr/bin/env python3
import importlib.util
import json
import sqlite3
import sys
from pathlib import Path

BASE = Path('/opt/xhttp-dual/controller.py')
if not BASE.exists():
    raise SystemExit(f'Missing base controller: {BASE}')

spec = importlib.util.spec_from_file_location('xhttp_dual_base', str(BASE))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def _table_exists(con, name):
    row = con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (name,)).fetchone()
    return bool(row)


def _fallback_users(rows):
    users = set()
    for row in rows:
        try:
            settings = json.loads(row['settings'] or '{}')
        except Exception:
            continue
        for client in settings.get('clients', []) or []:
            if not isinstance(client, dict):
                continue
            if client.get('enable', True) is False:
                continue
            email = str(client.get('email') or '').strip()
            if email:
                users.add(email)
    return users


def get_vless_users_and_tags(db_path):
    """Read the same client identities modern 3x-ui uses at runtime.

    New 3x-ui stores canonical clients in clients + client_inbounds and rebuilds
    inbound settings at runtime. Older versions keep clients only in
    inbounds.settings. Prefer the canonical tables and fall back safely.
    """
    con = mod.connect_db(db_path)
    try:
        cols = {r['name'] for r in con.execute('PRAGMA table_info(inbounds)')}
        required = {'tag', 'protocol', 'settings'}
        if not required.issubset(cols):
            raise RuntimeError(f'inbounds table missing columns: {sorted(required - cols)}')

        have_id = 'id' in cols
        enable_expr = 'enable' if 'enable' in cols else '1 AS enable'
        select_id = 'id,' if have_id else ''
        rows = con.execute(f'SELECT {select_id} tag, protocol, settings, {enable_expr} FROM inbounds').fetchall()
        vless_rows = [r for r in rows if str(r['protocol']).lower() == 'vless' and bool(r['enable'])]
        tags = sorted({str(r['tag']).strip() for r in vless_rows if str(r['tag'] or '').strip()})

        if have_id and vless_rows and _table_exists(con, 'clients') and _table_exists(con, 'client_inbounds'):
            ccols = {r['name'] for r in con.execute('PRAGMA table_info(clients)')}
            if {'id', 'email'}.issubset(ccols):
                ids = [int(r['id']) for r in vless_rows]
                ph = ','.join('?' for _ in ids)
                enable_filter = 'AND COALESCE(c.enable,1) != 0' if 'enable' in ccols else ''
                q = f'''\n                    SELECT DISTINCT TRIM(c.email) AS email\n                    FROM clients c\n                    JOIN client_inbounds ci ON ci.client_id = c.id\n                    WHERE ci.inbound_id IN ({ph})\n                      AND c.email IS NOT NULL\n                      AND TRIM(c.email) <> ''\n                      {enable_filter}\n                '''
                users = {str(r['email']).strip() for r in con.execute(q, ids).fetchall() if str(r['email'] or '').strip()}
                if users:
                    return sorted(users), tags

        return sorted(_fallback_users(vless_rows)), tags
    finally:
        con.close()


mod.get_vless_users_and_tags = get_vless_users_and_tags


def diagnose():
    cfg = mod.load_json(mod.CONFIG_PATH)
    state = mod.load_state()
    users, tags = get_vless_users_and_tags(cfg['db_path'])
    print('XHTTP DUAL USER ROUTING DIAG')
    print(f'canonical users={len(users)} tags={",".join(tags) or "-"}')
    print(f'state users={len(state.get("users", {}))}')
    current = set(users)
    mapped = set(state.get('users', {}))
    print(f'mapped-current={len(mapped & current)} stale={len(mapped-current)} missing={len(current-mapped)}')
    try:
        _, template = mod.read_xray_template(cfg['db_path'])
        rules = (template.get('routing') or {}).get('rules') or []
        for r in rules:
            if not isinstance(r, dict):
                continue
            tag = str(r.get('ruleTag') or '')
            if tag.startswith(mod.RULE_PREFIX):
                print(f'rule={tag} outbound={r.get("outboundTag")} users={len(r.get("user") or [])} inbound={r.get("inboundTag") or []}')
    except Exception as exc:
        print(f'template_error={exc}')


if __name__ == '__main__':
    try:
        if len(sys.argv) >= 2 and sys.argv[1] == 'diagnose':
            diagnose()
        else:
            mod.main()
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)

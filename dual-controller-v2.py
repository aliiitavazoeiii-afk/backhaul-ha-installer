#!/usr/bin/env python3
import importlib.util
import json
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
    """Use the same canonical client identities modern 3x-ui emits to Xray."""
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

        # Modern 3x-ui: clients are canonical in clients + client_inbounds.
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

        # Older x-ui compatibility.
        return sorted(_fallback_users(vless_rows)), tags
    finally:
        con.close()


def reconcile_users(state, users):
    """Sticky home assignment + failover + automatic route restore to home.

    Restoring effective->home only changes routing for NEW connections. Existing
    TCP sessions remain on the failover node until the client reconnects, which
    gives the gradual recovery behaviour wanted for this deployment.
    """
    changed = False
    current = set(users)

    for email in list(state['users']):
        if email not in current:
            del state['users'][email]
            changed = True

    avail = mod.available_nodes(state)

    for email in users:
        if email not in state['users']:
            node = mod.choose_node_for_new(state, avail)
            state['users'][email] = {
                'home': node,
                'effective': node,
                'created': mod.dt.datetime.now().isoformat(timespec='seconds'),
            }
            changed = True

    if not avail:
        return changed

    for email, u in state['users'].items():
        home = u.get('home')
        eff = u.get('effective')

        # Failed/drained current path: move to a healthy survivor.
        if eff not in avail:
            if len(avail) == 1:
                target = avail[0]
            elif home in avail:
                target = home
            else:
                counts = mod.assignment_counts(state)
                target = 'f1' if counts['f1'] <= counts['f2'] else 'f2'
            if eff != target:
                mod.log(f'failover user {email}: {eff} -> {target}')
                u['effective'] = target
                u['moved_at'] = mod.dt.datetime.now().isoformat(timespec='seconds')
                changed = True
            continue

        # Home recovered: restore routing immediately. Existing established
        # sessions do not migrate; users return gradually as they reconnect.
        if home in avail and eff != home:
            mod.log(f'restore user {email}: {eff} -> home {home}')
            u['effective'] = home
            u['restored_at'] = mod.dt.datetime.now().isoformat(timespec='seconds')
            changed = True

    return changed


mod.get_vless_users_and_tags = get_vless_users_and_tags
mod.reconcile_users = reconcile_users


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
    print(f'assigned={mod.assignment_counts(state)} home={mod.assignment_counts(state, key="home")}')
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

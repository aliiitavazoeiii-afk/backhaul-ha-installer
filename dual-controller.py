#!/usr/bin/env python3
import argparse
import copy
import datetime as dt
import fcntl
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

CONFIG_PATH = Path('/etc/xhttp-dual/config.json')
STATE_PATH = Path('/var/lib/xhttp-dual/state.json')
LOCK_PATH = Path('/var/lib/xhttp-dual/controller.lock')
BACKUP_DIR = Path('/var/lib/xhttp-dual/backups')
MANAGED_TAGS = {'xhttp-dual-f1', 'xhttp-dual-f2'}
RULE_PREFIX = 'xhttp-dual:'


def log(msg):
    print(f"[{dt.datetime.now().isoformat(timespec='seconds')}] {msg}", flush=True)


def load_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        if default is not None:
            return copy.deepcopy(default)
        raise


def atomic_write_json(path, obj, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(obj, indent=2, sort_keys=True) + '\n')
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def default_state():
    return {
        'version': 1,
        'rr_next': 'f1',
        'users': {},
        'nodes': {
            'f1': {'healthy': None, 'failures': 0, 'successes': 0, 'drained': False, 'last_change': None, 'last_check': None},
            'f2': {'healthy': None, 'failures': 0, 'successes': 0, 'drained': False, 'last_change': None, 'last_check': None},
        },
        'last_apply': None,
        'last_error': None,
    }


def load_state():
    state = load_json(STATE_PATH, default_state())
    base = default_state()
    for k, v in base.items():
        state.setdefault(k, copy.deepcopy(v))
    for node in ('f1', 'f2'):
        state['nodes'].setdefault(node, copy.deepcopy(base['nodes'][node]))
        for k, v in base['nodes'][node].items():
            state['nodes'][node].setdefault(k, copy.deepcopy(v))
    return state


def save_state(state):
    atomic_write_json(STATE_PATH, state)


def get_lock():
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    f = open(LOCK_PATH, 'w')
    fcntl.flock(f.fileno(), fcntl.LOCK_EX)
    return f


def run(cmd, timeout=None, check=False):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=check)


def health_check(node_cfg):
    host = node_cfg['socks_host']
    port = str(node_cfg['socks_port'])
    url = node_cfg.get('health_url') or 'https://cp.cloudflare.com/generate_204'
    timeout = int(node_cfg.get('health_timeout', 8))
    cmd = [
        'curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}',
        '--max-time', str(timeout), '--connect-timeout', str(max(2, timeout // 2)),
        '--socks5-hostname', f'{host}:{port}', url,
    ]
    try:
        p = run(cmd, timeout=timeout + 3)
        code = p.stdout.strip()
        ok = p.returncode == 0 and code in {'200', '204'}
        return ok, f'http={code or "-"} rc={p.returncode}'
    except Exception as exc:
        return False, str(exc)


def update_health(state, cfg):
    changed = False
    fth = int(cfg.get('failure_threshold', 3))
    rth = int(cfg.get('recovery_threshold', 5))
    for node in ('f1', 'f2'):
        nstate = state['nodes'][node]
        ok, detail = health_check(cfg['nodes'][node])
        nstate['last_check'] = dt.datetime.now().isoformat(timespec='seconds')
        nstate['last_detail'] = detail
        old = nstate.get('healthy')
        if ok:
            nstate['failures'] = 0
            nstate['successes'] = int(nstate.get('successes', 0)) + 1
            if old is None or (old is False and nstate['successes'] >= rth):
                nstate['healthy'] = True
        else:
            nstate['successes'] = 0
            nstate['failures'] = int(nstate.get('failures', 0)) + 1
            if old is True and nstate['failures'] >= fth:
                nstate['healthy'] = False
            elif old is None and nstate['failures'] >= fth:
                nstate['healthy'] = False
        if old != nstate.get('healthy'):
            nstate['last_change'] = dt.datetime.now().isoformat(timespec='seconds')
            changed = True
            log(f'{node} health {old} -> {nstate.get("healthy")} ({detail})')
    return changed


def available_nodes(state):
    return [n for n in ('f1', 'f2') if state['nodes'][n].get('healthy') is True and not state['nodes'][n].get('drained', False)]


def connect_db(db_path):
    con = sqlite3.connect(db_path, timeout=15)
    con.row_factory = sqlite3.Row
    return con


def get_vless_users_and_tags(db_path):
    con = connect_db(db_path)
    try:
        cols = {r['name'] for r in con.execute('PRAGMA table_info(inbounds)')}
        required = {'tag', 'protocol', 'settings'}
        if not required.issubset(cols):
            raise RuntimeError(f'inbounds table missing columns: {sorted(required - cols)}')
        enable_expr = 'enable' if 'enable' in cols else '1 AS enable'
        rows = con.execute(f'SELECT tag, protocol, settings, {enable_expr} FROM inbounds').fetchall()
    finally:
        con.close()

    users = set()
    tags = []
    for row in rows:
        if str(row['protocol']).lower() != 'vless' or not bool(row['enable']):
            continue
        tags.append(row['tag'])
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
    return sorted(users), sorted(set(tags))


def assignment_counts(state, key='effective'):
    out = {'f1': 0, 'f2': 0}
    for u in state['users'].values():
        n = u.get(key)
        if n in out:
            out[n] += 1
    return out


def choose_node_for_new(state, avail):
    if not avail:
        return state.get('rr_next', 'f1')
    if len(avail) == 1:
        return avail[0]
    counts = assignment_counts(state)
    if counts['f1'] < counts['f2']:
        node = 'f1'
    elif counts['f2'] < counts['f1']:
        node = 'f2'
    else:
        node = state.get('rr_next', 'f1')
    state['rr_next'] = 'f2' if node == 'f1' else 'f1'
    return node


def reconcile_users(state, users):
    changed = False
    current = set(users)
    for email in list(state['users']):
        if email not in current:
            del state['users'][email]
            changed = True
    avail = available_nodes(state)
    for email in users:
        if email not in state['users']:
            node = choose_node_for_new(state, avail)
            state['users'][email] = {'home': node, 'effective': node, 'created': dt.datetime.now().isoformat(timespec='seconds')}
            changed = True
    if avail:
        for email, u in state['users'].items():
            eff = u.get('effective')
            if eff not in avail:
                if len(avail) == 1:
                    target = avail[0]
                else:
                    counts = assignment_counts(state)
                    target = 'f1' if counts['f1'] <= counts['f2'] else 'f2'
                if eff != target:
                    log(f'failover user {email}: {eff} -> {target}')
                    u['effective'] = target
                    u['moved_at'] = dt.datetime.now().isoformat(timespec='seconds')
                    changed = True
    return changed


def unwrap_template(obj):
    seen = 0
    while isinstance(obj, dict) and 'xraySetting' in obj and isinstance(obj['xraySetting'], (dict, str)) and seen < 8:
        obj = obj['xraySetting']
        if isinstance(obj, str):
            obj = json.loads(obj)
        seen += 1
    if not isinstance(obj, dict):
        raise RuntimeError('xrayTemplateConfig is not a JSON object')
    return obj


def read_xray_template(db_path):
    con = connect_db(db_path)
    try:
        row = con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
        if not row:
            raise RuntimeError('settings.xrayTemplateConfig not found')
        raw = row['value']
    finally:
        con.close()
    obj = json.loads(raw)
    return raw, unwrap_template(obj)


def strip_managed(template):
    t = copy.deepcopy(template)
    outbounds = t.get('outbounds') or []
    t['outbounds'] = [o for o in outbounds if not (isinstance(o, dict) and o.get('tag') in MANAGED_TAGS)]
    routing = t.setdefault('routing', {})
    rules = routing.get('rules') or []
    cleaned = []
    for r in rules:
        if not isinstance(r, dict):
            cleaned.append(r)
            continue
        if str(r.get('ruleTag') or '').startswith(RULE_PREFIX):
            continue
        if r.get('outboundTag') in MANAGED_TAGS:
            continue
        cleaned.append(r)
    routing['rules'] = cleaned
    return t


def generic_catchall(rule):
    if not isinstance(rule, dict):
        return False
    match_keys = {'domain','ip','port','sourceIP','sourcePort','localIP','localPort','user','inboundTag','protocol','attrs','process','vlessRoute'}
    if any(k in rule and rule.get(k) not in (None, [], '', {}) for k in match_keys):
        return False
    net = rule.get('network')
    return net in (None, '', 'tcp,udp', 'udp,tcp')


def build_managed_template(base, state, cfg, inbound_tags):
    t = strip_managed(base)
    t.setdefault('outbounds', [])
    for node in ('f1', 'f2'):
        nc = cfg['nodes'][node]
        t['outbounds'].append({
            'tag': f'xhttp-dual-{node}',
            'protocol': 'socks',
            'settings': {'servers': [{'address': nc['socks_host'], 'port': int(nc['socks_port'])}]},
        })

    by_node = {'f1': [], 'f2': []}
    for email, u in sorted(state['users'].items()):
        eff = u.get('effective')
        if eff in by_node:
            by_node[eff].append(email)

    managed_rules = []
    for node in ('f1', 'f2'):
        if by_node[node]:
            rule = {
                'type': 'field',
                'network': 'tcp,udp',
                'user': by_node[node],
                'outboundTag': f'xhttp-dual-{node}',
                'ruleTag': f'{RULE_PREFIX}{node}-users',
            }
            if inbound_tags:
                rule['inboundTag'] = inbound_tags
            managed_rules.append(rule)

    if cfg.get('managed_fallback', True) and inbound_tags:
        avail = available_nodes(state)
        fallback = avail[0] if avail else 'f1'
        managed_rules.append({
            'type': 'field',
            'network': 'tcp,udp',
            'inboundTag': inbound_tags,
            'outboundTag': f'xhttp-dual-{fallback}',
            'ruleTag': f'{RULE_PREFIX}fallback',
        })

    routing = t.setdefault('routing', {})
    rules = routing.setdefault('rules', [])
    idx = len(rules)
    for i, r in enumerate(rules):
        if generic_catchall(r):
            idx = i
            break
    routing['rules'] = rules[:idx] + managed_rules + rules[idx:]
    return t


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'))


def backup_db(db_path):
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    dest = BACKUP_DIR / f'x-ui-{stamp}.db'
    src = connect_db(db_path)
    dst = sqlite3.connect(dest)
    try:
        src.backup(dst)
    finally:
        dst.close(); src.close()
    backups = sorted(BACKUP_DIR.glob('x-ui-*.db'))
    for old in backups[:-20]:
        try:
            old.unlink()
        except OSError:
            pass
    return dest


def write_template_and_restart(db_path, old_raw, new_template, xui_service):
    new_raw = json.dumps(new_template, separators=(',', ':'))
    backup = backup_db(db_path)
    con = connect_db(db_path)
    try:
        con.execute('BEGIN IMMEDIATE')
        cur = con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (new_raw,))
        if cur.rowcount != 1:
            raise RuntimeError('failed to update xrayTemplateConfig')
        con.commit()
    except Exception:
        con.rollback(); con.close(); raise
    con.close()

    p = run(['systemctl', 'restart', xui_service], timeout=30)
    active = run(['systemctl', 'is-active', xui_service], timeout=10)
    if p.returncode != 0 or active.stdout.strip() != 'active':
        log(f'x-ui restart failed; rolling back template from {backup}')
        con = connect_db(db_path)
        try:
            con.execute('BEGIN IMMEDIATE')
            con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (old_raw,))
            con.commit()
        finally:
            con.close()
        run(['systemctl', 'restart', xui_service], timeout=30)
        raise RuntimeError(f'{xui_service} failed after config update: {p.stderr.strip()}')
    return backup


def apply_routing(state, cfg, inbound_tags, force=False):
    db_path = cfg['db_path']
    old_raw, current = read_xray_template(db_path)
    desired = build_managed_template(current, state, cfg, inbound_tags)
    if not force and canonical(current) == canonical(desired):
        return False
    backup = write_template_and_restart(db_path, old_raw, desired, cfg.get('xui_service', 'x-ui'))
    state['last_apply'] = dt.datetime.now().isoformat(timespec='seconds')
    state['last_apply_backup'] = str(backup)
    log(f'Applied sticky routing; x-ui restarted. backup={backup}')
    return True


def sync_once(force=False):
    cfg = load_json(CONFIG_PATH)
    state = load_state()
    update_health(state, cfg)
    users, tags = get_vless_users_and_tags(cfg['db_path'])
    reconcile_users(state, users)
    try:
        apply_routing(state, cfg, tags, force=force)
        state['last_error'] = None
    except Exception as exc:
        state['last_error'] = str(exc)
        save_state(state)
        raise
    save_state(state)
    return state, tags


def status():
    cfg = load_json(CONFIG_PATH)
    state = load_state()
    users, tags = get_vless_users_and_tags(cfg['db_path'])
    counts = assignment_counts(state)
    print('XHTTP DUAL STICKY FAILOVER')
    print(f'VLESS users: {len(users)} | inbound tags: {", ".join(tags) or "-"}')
    for node in ('f1', 'f2'):
        n = state['nodes'][node]
        nc = cfg['nodes'][node]
        print(f'{node.upper()}: healthy={n.get("healthy")} drained={n.get("drained")} assigned={counts[node]} socks={nc["socks_host"]}:{nc["socks_port"]} failures={n.get("failures",0)} successes={n.get("successes",0)}')
        print(f'    last_check={n.get("last_check")} detail={n.get("last_detail","-")}')
    print(f'last_apply={state.get("last_apply")}')
    if state.get('last_error'):
        print(f'last_error={state["last_error"]}')


def rebalance(yes=False):
    if not yes:
        raise RuntimeError("rebalance can change users' public IPs. Re-run: xhttp-dual rebalance --yes")
    cfg = load_json(CONFIG_PATH)
    with get_lock():
        state = load_state()
        update_health(state, cfg)
        avail = available_nodes(state)
        if set(avail) != {'f1', 'f2'}:
            raise RuntimeError('both foreign nodes must be healthy and undrained before rebalance')
        users, tags = get_vless_users_and_tags(cfg['db_path'])
        for email in list(state['users']):
            if email not in users:
                del state['users'][email]
        for idx, email in enumerate(users):
            node = 'f1' if idx % 2 == 0 else 'f2'
            state['users'][email] = {'home': node, 'effective': node, 'rebalanced_at': dt.datetime.now().isoformat(timespec='seconds')}
        state['rr_next'] = 'f1' if len(users) % 2 == 0 else 'f2'
        apply_routing(state, cfg, tags, force=True)
        save_state(state)
        log(f'Rebalanced {len(users)} users 50/50')


def set_drain(node, value):
    if node not in ('f1', 'f2'):
        raise RuntimeError('node must be f1 or f2')
    with get_lock():
        state = load_state()
        state['nodes'][node]['drained'] = bool(value)
        state['nodes'][node]['last_change'] = dt.datetime.now().isoformat(timespec='seconds')
        save_state(state)
        sync_once(force=True)
        log(f'{node} drained={value}')


def remove_managed():
    cfg = load_json(CONFIG_PATH)
    with get_lock():
        old_raw, current = read_xray_template(cfg['db_path'])
        cleaned = strip_managed(current)
        if canonical(cleaned) == canonical(current):
            log('No managed x-ui routing/outbounds found.')
            return
        backup = write_template_and_restart(cfg['db_path'], old_raw, cleaned, cfg.get('xui_service', 'x-ui'))
        log(f'Removed managed x-ui routing/outbounds. backup={backup}')


def daemon():
    cfg = load_json(CONFIG_PATH)
    interval = int(cfg.get('check_interval', 15))
    log(f'controller started interval={interval}s')
    while True:
        try:
            with get_lock():
                sync_once()
        except Exception as exc:
            log(f'ERROR: {exc}')
            try:
                state = load_state(); state['last_error'] = str(exc); save_state(state)
            except Exception:
                pass
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(prog='xhttp-dual')
    sub = parser.add_subparsers(dest='cmd', required=True)
    sub.add_parser('daemon')
    sub.add_parser('sync')
    sub.add_parser('status')
    p = sub.add_parser('rebalance'); p.add_argument('--yes', action='store_true')
    p = sub.add_parser('drain'); p.add_argument('node', choices=['f1','f2'])
    p = sub.add_parser('undrain'); p.add_argument('node', choices=['f1','f2'])
    sub.add_parser('remove-managed')
    args = parser.parse_args()

    if args.cmd == 'daemon':
        daemon()
    elif args.cmd == 'sync':
        with get_lock():
            sync_once(force=True)
        status()
    elif args.cmd == 'status':
        status()
    elif args.cmd == 'rebalance':
        rebalance(args.yes)
    elif args.cmd == 'drain':
        set_drain(args.node, True)
    elif args.cmd == 'undrain':
        set_drain(args.node, False)
    elif args.cmd == 'remove-managed':
        remove_managed()


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)

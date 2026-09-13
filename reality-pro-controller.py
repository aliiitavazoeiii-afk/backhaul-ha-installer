#!/usr/bin/env python3
import argparse
import copy
import datetime as dt
import json
import os
import random
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CONFIG_PATH = Path('/etc/reality-pro/config.json')
STATE_PATH = Path('/var/lib/reality-pro/state.json')
LOCK_PATH = Path('/run/reality-pro.lock')
BACKUP_DIR = Path('/var/lib/reality-pro/backups')
LOG_PATH = Path('/var/log/reality-pro.log')
MANAGED_OUTBOUNDS = {'reality-pro-home-f1', 'reality-pro-home-f2'}
RULE_PREFIX = 'reality-pro:'
_rng = random.SystemRandom()


def now():
    return dt.datetime.now().isoformat(timespec='seconds')


def log(msg):
    line = f'[{now()}] {msg}'
    print(line, flush=True)
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open('a', encoding='utf-8') as f:
            f.write(line + '\n')
    except Exception:
        pass


def run(cmd, timeout=30, check=False):
    p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(f"command failed rc={p.returncode}: {' '.join(cmd)} :: {p.stderr.strip()}")
    return p


def load_json(path):
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)


def atomic_json(path, obj, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(obj, f, indent=2, sort_keys=True)
            f.write('\n')
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except Exception:
            pass


def load_state():
    if not STATE_PATH.exists():
        return {
            'version': 1,
            'rr_next': 'f1',
            'users': {},
            'nodes': {
                'f1': {'healthy': True, 'drained': False, 'failures': 0, 'successes': 0},
                'f2': {'healthy': True, 'drained': False, 'failures': 0, 'successes': 0},
            },
            'routes': {'home_f1': 'f1', 'home_f2': 'f2'},
            'last_apply': None,
            'last_error': None,
            'next_probe': {'f1': 0.0, 'f2': 0.0},
            'last_user_sync_epoch': 0.0,
        }
    s = load_json(STATE_PATH)
    s.setdefault('users', {})
    s.setdefault('nodes', {})
    for n in ('f1', 'f2'):
        ns = s['nodes'].setdefault(n, {})
        ns.setdefault('healthy', True)
        ns.setdefault('drained', False)
        ns.setdefault('failures', 0)
        ns.setdefault('successes', 0)
    s.setdefault('routes', {'home_f1': 'f1', 'home_f2': 'f2'})
    s.setdefault('next_probe', {'f1': 0.0, 'f2': 0.0})
    s.setdefault('rr_next', 'f1')
    s.setdefault('last_apply', None)
    s.setdefault('last_error', None)
    s.setdefault('last_user_sync_epoch', 0.0)
    return s


def save_state(s):
    atomic_json(STATE_PATH, s)


class FileLock:
    def __enter__(self):
        import fcntl
        self.f = open(LOCK_PATH, 'w')
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, tb):
        import fcntl
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def connect_db(path):
    con = sqlite3.connect(path, timeout=15)
    con.row_factory = sqlite3.Row
    return con


def _table_exists(con, name):
    return bool(con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (name,)).fetchone())


def _fallback_users(rows):
    users = set()
    for row in rows:
        try:
            settings = json.loads(row['settings'] or '{}')
        except Exception:
            continue
        for c in settings.get('clients', []) or []:
            if not isinstance(c, dict) or c.get('enable', True) is False:
                continue
            email = str(c.get('email') or '').strip()
            if email:
                users.add(email)
    return users


def get_vless_users_and_tags(db_path):
    con = connect_db(db_path)
    try:
        cols = {r['name'] for r in con.execute('PRAGMA table_info(inbounds)')}
        required = {'tag', 'protocol', 'settings'}
        if not required.issubset(cols):
            raise RuntimeError(f'inbounds table missing columns: {sorted(required-cols)}')
        have_id = 'id' in cols
        enable_expr = 'enable' if 'enable' in cols else '1 AS enable'
        select_id = 'id,' if have_id else ''
        rows = con.execute(f'SELECT {select_id} tag, protocol, settings, {enable_expr} FROM inbounds').fetchall()
        vrows = [r for r in rows if str(r['protocol']).lower() == 'vless' and bool(r['enable'])]
        tags = sorted({str(r['tag']).strip() for r in vrows if str(r['tag'] or '').strip()})
        if have_id and vrows and _table_exists(con, 'clients') and _table_exists(con, 'client_inbounds'):
            ccols = {r['name'] for r in con.execute('PRAGMA table_info(clients)')}
            if {'id', 'email'}.issubset(ccols):
                ids = [int(r['id']) for r in vrows]
                ph = ','.join('?' for _ in ids)
                ef = 'AND COALESCE(c.enable,1) != 0' if 'enable' in ccols else ''
                q = f'''SELECT DISTINCT TRIM(c.email) AS email
                        FROM clients c JOIN client_inbounds ci ON ci.client_id=c.id
                        WHERE ci.inbound_id IN ({ph})
                          AND c.email IS NOT NULL AND TRIM(c.email) <> '' {ef}'''
                users = {str(r['email']).strip() for r in con.execute(q, ids).fetchall() if str(r['email'] or '').strip()}
                if users:
                    return sorted(users), tags
        return sorted(_fallback_users(vrows)), tags
    finally:
        con.close()


def home_counts(state):
    out = {'f1': 0, 'f2': 0}
    for u in state['users'].values():
        h = u.get('home')
        if h in out:
            out[h] += 1
    return out


def reconcile_users(state, users):
    changed = False
    current = set(users)
    for email in list(state['users']):
        if email not in current:
            del state['users'][email]
            changed = True
    for email in users:
        if email in state['users']:
            continue
        counts = home_counts(state)
        if counts['f1'] < counts['f2']:
            h = 'f1'
        elif counts['f2'] < counts['f1']:
            h = 'f2'
        else:
            h = state.get('rr_next', 'f1')
            state['rr_next'] = 'f2' if h == 'f1' else 'f1'
        state['users'][email] = {'home': h, 'created': now()}
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


def read_template(db_path):
    con = connect_db(db_path)
    try:
        row = con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
        if not row:
            raise RuntimeError('settings.xrayTemplateConfig not found')
        raw = row['value']
    finally:
        con.close()
    return raw, unwrap_template(json.loads(raw))


def generic_catchall(rule):
    if not isinstance(rule, dict):
        return False
    keys = {'domain','ip','port','sourceIP','sourcePort','localIP','localPort','user','inboundTag','protocol','attrs','process','vlessRoute'}
    if any(k in rule and rule.get(k) not in (None, [], '', {}) for k in keys):
        return False
    return rule.get('network') in (None, '', 'tcp,udp', 'udp,tcp')


def strip_managed(template):
    t = copy.deepcopy(template)
    t['outbounds'] = [o for o in (t.get('outbounds') or []) if not (isinstance(o, dict) and o.get('tag') in MANAGED_OUTBOUNDS)]
    rt = t.setdefault('routing', {})
    cleaned = []
    for r in rt.get('rules') or []:
        if not isinstance(r, dict):
            cleaned.append(r); continue
        if str(r.get('ruleTag') or '').startswith(RULE_PREFIX):
            continue
        if r.get('outboundTag') in MANAGED_OUTBOUNDS:
            continue
        cleaned.append(r)
    rt['rules'] = cleaned
    return t


def build_template(base, state, cfg, inbound_tags):
    t = strip_managed(base)
    t.setdefault('outbounds', [])
    for n in ('f1', 'f2'):
        t['outbounds'].append({
            'tag': f'reality-pro-home-{n}',
            'protocol': 'socks',
            'settings': {'servers': [{'address': '127.0.0.1', 'port': int(cfg['home_ports'][n])}]},
        })
    by = {'f1': [], 'f2': []}
    for email, u in sorted(state['users'].items()):
        h = u.get('home')
        if h in by:
            by[h].append(email)
    managed = []
    for n in ('f1', 'f2'):
        if by[n]:
            r = {
                'type': 'field', 'network': 'tcp,udp', 'user': by[n],
                'outboundTag': f'reality-pro-home-{n}', 'ruleTag': f'{RULE_PREFIX}{n}-users'
            }
            if inbound_tags:
                r['inboundTag'] = inbound_tags
            managed.append(r)
    if inbound_tags:
        managed.append({
            'type': 'field', 'network': 'tcp,udp', 'inboundTag': inbound_tags,
            'outboundTag': 'reality-pro-home-f1', 'ruleTag': f'{RULE_PREFIX}fallback'
        })
    rt = t.setdefault('routing', {})
    rules = rt.setdefault('rules', [])
    idx = len(rules)
    for i, r in enumerate(rules):
        if generic_catchall(r):
            idx = i; break
    rt['rules'] = rules[:idx] + managed + rules[idx:]
    return t


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'))


def backup_db(db_path):
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    dest = BACKUP_DIR / f"x-ui-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}.db"
    src = connect_db(db_path)
    dst = sqlite3.connect(dest)
    try:
        src.backup(dst)
    finally:
        dst.close(); src.close()
    backups = sorted(BACKUP_DIR.glob('x-ui-*.db'))
    for old in backups[:-20]:
        try: old.unlink()
        except OSError: pass
    return dest


def apply_user_routing(state, cfg, tags, force=False):
    old_raw, current = read_template(cfg['db_path'])
    desired = build_template(current, state, cfg, tags)
    if not force and canonical(current) == canonical(desired):
        return False
    backup = backup_db(cfg['db_path'])
    con = connect_db(cfg['db_path'])
    try:
        con.execute('BEGIN IMMEDIATE')
        cur = con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(desired, separators=(',', ':')),))
        if cur.rowcount != 1:
            raise RuntimeError('failed to update xrayTemplateConfig')
        con.commit()
    except Exception:
        con.rollback(); con.close(); raise
    con.close()
    p = run(['systemctl', 'restart', cfg.get('xui_service','x-ui')], timeout=30)
    active = run(['systemctl', 'is-active', cfg.get('xui_service','x-ui')], timeout=10)
    if p.returncode != 0 or active.stdout.strip() != 'active':
        con = connect_db(cfg['db_path'])
        try:
            con.execute('BEGIN IMMEDIATE')
            con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (old_raw,))
            con.commit()
        finally:
            con.close()
        run(['systemctl', 'restart', cfg.get('xui_service','x-ui')], timeout=30)
        raise RuntimeError(f'x-ui restart failed; restored backup {backup}')
    state['last_apply'] = now()
    state['last_apply_backup'] = str(backup)
    log(f'user map changed; x-ui restarted once. backup={backup}')
    return True


def xray_bo(cfg, balancer, node):
    tag = f'rp-node-{node}'
    p = run([cfg['xray_bin'], 'api', 'bo', f"--server={cfg['api_listen']}", '-b', balancer, tag], timeout=8)
    if p.returncode != 0:
        raise RuntimeError(f'balancer override {balancer}->{tag} failed: {p.stderr.strip()}')


def desired_target_for_home(state, home):
    own = home
    other = 'f2' if home == 'f1' else 'f1'
    ns = state['nodes']
    if ns[own].get('healthy') and not ns[own].get('drained'):
        return own
    if ns[other].get('healthy') and not ns[other].get('drained'):
        return other
    return state['routes'].get(f'home_{home}', own)


def reconcile_fabric_routes(state, cfg, force=False):
    changed = False
    for home in ('f1', 'f2'):
        key = f'home_{home}'
        desired = desired_target_for_home(state, home)
        old = state['routes'].get(key, home)
        if force or desired != old:
            xray_bo(cfg, f'rp-home-{home}-bal', desired)
            state['routes'][key] = desired
            if desired != old:
                state['routes_changed_at'] = now()
                log(f'live fabric switch {key}: {old} -> {desired} (NO x-ui restart)')
                changed = True
    return changed


def fabric_pid():
    p = run(['systemctl','show','-p','MainPID','--value','reality-pro-fabric.service'], timeout=5)
    try:
        return int((p.stdout or '0').strip() or 0)
    except Exception:
        return 0


def curl_probe(port, url, timeout=12):
    started = time.monotonic()
    p = run(['curl','-sS','-o','/dev/null','-w','%{http_code}', '--max-time', str(timeout), '--connect-timeout', '5',
             '--socks5-hostname', f'127.0.0.1:{port}', url], timeout=timeout+3)
    ms = int(round((time.monotonic()-started)*1000))
    code = p.stdout.strip()
    ok = p.returncode == 0 and code in ('200','204')
    return ok, code or '000', p.returncode, ms


def schedule_next(state, cfg, node, healthy):
    if healthy:
        lo = float(cfg.get('healthy_probe_min_s',75)); hi = float(cfg.get('healthy_probe_max_s',180))
    else:
        lo = float(cfg.get('unhealthy_probe_min_s',15)); hi = float(cfg.get('unhealthy_probe_max_s',35))
    delay = _rng.uniform(lo, hi)
    state['next_probe'][node] = time.time() + delay
    state['nodes'][node]['next_probe_in_s'] = round(delay,1)


def probe_node(state, cfg, node):
    ns = state['nodes'][node]
    urls = list(cfg.get('health_urls') or [
        'https://cp.cloudflare.com/generate_204',
        'https://connectivitycheck.gstatic.com/generate_204',
        'https://captive.apple.com/hotspot-detect.html'])
    _rng.shuffle(urls)
    attempts = []
    ok = False
    last = None
    for url in urls[:2]:
        r = curl_probe(int(cfg['probe_ports'][node]), url, int(cfg.get('health_timeout_s',12)))
        last = r
        attempts.append(f"{url.split('/')[2]}:http={r[1]}/rc={r[2]}/ms={r[3]}")
        if r[0]:
            ok = True; break
    old = bool(ns.get('healthy', True))
    ns['last_check'] = now()
    ns['last_detail'] = ';'.join(attempts)
    if last:
        ns['last_latency_ms'] = last[3]
    if ok:
        ns['failures'] = 0
        ns['successes'] = int(ns.get('successes',0)) + 1
        if not old and ns['successes'] >= int(cfg.get('recovery_threshold',3)):
            ns['healthy'] = True
    else:
        ns['successes'] = 0
        ns['failures'] = int(ns.get('failures',0)) + 1
        if old and ns['failures'] >= int(cfg.get('failure_threshold',3)):
            ns['healthy'] = False
    if old != bool(ns.get('healthy')):
        ns['last_change'] = now()
        log(f'{node} health {old} -> {ns.get("healthy")} ({ns["last_detail"]})')
    schedule_next(state, cfg, node, bool(ns.get('healthy')))
    return old != bool(ns.get('healthy'))


def local_fabric_ok(cfg):
    host, port = cfg['api_listen'].rsplit(':',1)
    try:
        with socket.create_connection((host, int(port)), timeout=2):
            return True
    except Exception:
        return False


def user_sync(state, cfg, force=False):
    users, tags = get_vless_users_and_tags(cfg['db_path'])
    changed = reconcile_users(state, users)
    if changed or force:
        apply_user_routing(state, cfg, tags, force=force)
    state['last_user_sync'] = now()
    return changed, users, tags


def init_probe_schedule(state, cfg):
    if any(float(v or 0) > 0 for v in state.get('next_probe',{}).values()):
        return
    base = time.time()
    state['next_probe'] = {'f1': base + _rng.uniform(2,8), 'f2': base + _rng.uniform(10,20)}


def sync_once(force_users=False, do_health=True):
    cfg = load_json(CONFIG_PATH)
    state = load_state()
    if not local_fabric_ok(cfg):
        state['last_error'] = 'reality-pro fabric API unavailable'
        save_state(state)
        raise RuntimeError(state['last_error'])
    init_probe_schedule(state, cfg)
    if do_health:
        t = time.time()
        due = [n for n in ('f1','f2') if t >= float(state['next_probe'].get(n,0))]
        _rng.shuffle(due)
        for n in due:
            probe_node(state, cfg, n)
        pid = fabric_pid()
        force_routes = pid > 0 and pid != int(state.get('fabric_pid',0) or 0)
        if pid > 0:
            state['fabric_pid'] = pid
        reconcile_fabric_routes(state, cfg, force=force_routes)
    interval = float(cfg.get('user_sync_interval_s',60))
    if force_users or time.time() - float(state.get('last_user_sync_epoch',0)) >= interval:
        user_sync(state, cfg, force=force_users)
        state['last_user_sync_epoch'] = time.time()
    state['last_error'] = None
    save_state(state)
    return state


def daemon():
    cfg = load_json(CONFIG_PATH)
    log(f"reality-pro controller started: external healthy probes={cfg.get('healthy_probe_min_s',75)}-{cfg.get('healthy_probe_max_s',180)}s")
    while True:
        try:
            with FileLock():
                sync_once()
        except Exception as exc:
            log(f'ERROR: {exc}')
            try:
                s = load_state(); s['last_error'] = str(exc); save_state(s)
            except Exception:
                pass
        time.sleep(_rng.uniform(float(cfg.get('controller_tick_min_s',5)), float(cfg.get('controller_tick_max_s',12))))


def status():
    cfg = load_json(CONFIG_PATH); s = load_state()
    users, tags = get_vless_users_and_tags(cfg['db_path'])
    print('REALITY PRO STICKY FAILOVER')
    print(f'VLESS users: {len(users)} | inbound tags: {", ".join(tags) or "-"}')
    print(f'home={home_counts(s)} routes={s.get("routes") or {}}')
    for n in ('f1','f2'):
        ns=s['nodes'][n]
        print(f"{n.upper()}: healthy={ns.get('healthy')} drained={ns.get('drained')} probe_socks=127.0.0.1:{cfg['probe_ports'][n]} failures={ns.get('failures',0)} successes={ns.get('successes',0)}")
        print(f"    last_check={ns.get('last_check')} detail={ns.get('last_detail','-')} next_probe_in_s={ns.get('next_probe_in_s','-')}")
    print(f"fabric_api={cfg['api_listen']} x-ui-last-user-map-apply={s.get('last_apply')}")


def diagnose():
    cfg=load_json(CONFIG_PATH); s=load_state(); users,tags=get_vless_users_and_tags(cfg['db_path'])
    current=set(users); mapped=set(s['users'])
    print('REALITY PRO DIAG')
    print(f'canonical users={len(users)} tags={",".join(tags) or "-"}')
    print(f'state users={len(mapped)} mapped-current={len(mapped&current)} stale={len(mapped-current)} missing={len(current-mapped)}')
    print(f'home={home_counts(s)} routes={s.get("routes") or {}}')
    print(f'fabric_api_ok={local_fabric_ok(cfg)}')
    try:
        _, t = read_template(cfg['db_path'])
        for r in (t.get('routing') or {}).get('rules') or []:
            if isinstance(r,dict) and str(r.get('ruleTag') or '').startswith(RULE_PREFIX):
                print(f"rule={r.get('ruleTag')} outbound={r.get('outboundTag')} users={len(r.get('user') or [])} inbound={r.get('inboundTag') or []}")
    except Exception as exc:
        print(f'template_error={exc}')


def netcheck():
    cfg=load_json(CONFIG_PATH)
    print('REALITY PRO NETWORK CHECK')
    for n in ('f1','f2'):
        nc=cfg['nodes'][n]
        started=time.monotonic()
        try:
            with socket.create_connection((nc['foreign_ip'], int(nc['foreign_port'])), timeout=5):
                tcp='ok'
        except Exception as exc:
            tcp=f'failed:{exc}'
        ms=int(round((time.monotonic()-started)*1000))
        ok,code,rc,tms=curl_probe(int(cfg['probe_ports'][n]), 'https://cp.cloudflare.com/generate_204', 12)
        print(f"{n.upper()}: foreign={nc['foreign_ip']}:{nc['foreign_port']} tcp={tcp} tcp_ms={ms} tunnel={'ok' if ok else 'failed'} http={code} rc={rc} tunnel_ms={tms}")


def set_drain(node, value):
    cfg=load_json(CONFIG_PATH); s=load_state()
    s['nodes'][node]['drained']=value
    reconcile_fabric_routes(s,cfg)
    save_state(s)
    print(f'{node} drained={value}; routes={s["routes"]}')


def rebalance(confirm):
    if not confirm:
        raise RuntimeError('rebalance requires --yes')
    cfg=load_json(CONFIG_PATH); s=load_state(); users,tags=get_vless_users_and_tags(cfg['db_path'])
    ordered=sorted(users)
    for i,email in enumerate(ordered):
        s['users'].setdefault(email, {'created':now()})['home'] = 'f1' if i%2==0 else 'f2'
    for email in list(s['users']):
        if email not in set(users): del s['users'][email]
    apply_user_routing(s,cfg,tags,force=True)
    save_state(s)
    print(f'rebalanced: home={home_counts(s)}')


def main():
    ap=argparse.ArgumentParser(prog='reality-pro')
    sub=ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('daemon'); sub.add_parser('status'); sub.add_parser('diagnose'); sub.add_parser('netcheck')
    sub.add_parser('sync')
    for n in ('drain','undrain'):
        p=sub.add_parser(n); p.add_argument('node', choices=['f1','f2'])
    p=sub.add_parser('rebalance'); p.add_argument('--yes', action='store_true')
    a=ap.parse_args()
    if a.cmd=='daemon': daemon()
    elif a.cmd=='status': status()
    elif a.cmd=='diagnose': diagnose()
    elif a.cmd=='netcheck': netcheck()
    elif a.cmd=='sync':
        with FileLock(): sync_once(force_users=True, do_health=False)
        status()
    elif a.cmd=='drain':
        with FileLock(): set_drain(a.node, True)
    elif a.cmd=='undrain':
        with FileLock(): set_drain(a.node, False)
    elif a.cmd=='rebalance':
        with FileLock(): rebalance(a.yes)


if __name__=='__main__':
    try:
        main()
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)

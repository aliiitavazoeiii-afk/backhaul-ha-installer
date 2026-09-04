#!/usr/bin/env python3
import argparse
import json
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CONFIG_PATH = Path('/etc/maya-watchdog/config.json')
STATE_PATH = Path('/var/lib/maya-watchdog/state.json')


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')


def load_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        if default is not None:
            return default
        raise


def atomic_json(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.write('\n')
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def run(cmd, timeout=15):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)


def ssh_cmd(target, command, timeout=20):
    cmd = [
        'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=7',
        '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2',
        '-p', str(target.get('port', 22)),
    ]
    key = str(target.get('key') or '').strip()
    if key:
        cmd += ['-i', key]
    cmd += [f"{target.get('user', 'root')}@{target['host']}", command]
    return run(cmd, timeout=timeout)


def tcp_check(host, port, timeout=5):
    started = time.monotonic()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True, round((time.monotonic() - started) * 1000), 'tcp-ok'
    except Exception as exc:
        return False, None, f'{type(exc).__name__}: {exc}'


def telegram_send(cfg, text):
    tg = cfg.get('telegram') or {}
    token = str(tg.get('bot_token') or '').strip()
    chat = str(tg.get('chat_id') or '').strip()
    if not token or not chat:
        return
    data = urllib.parse.urlencode({'chat_id': chat, 'text': text}).encode()
    req = urllib.request.Request(f'https://api.telegram.org/bot{token}/sendMessage', data=data)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            r.read()
    except Exception as exc:
        print(f'[telegram] {exc}', file=sys.stderr, flush=True)


def parse_kv(text):
    out = {}
    for line in text.splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            out[k.strip()] = v.strip()
    return out


def recursive_find_key(obj, wanted):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if str(k).lower() == wanted.lower():
                return v
        for v in obj.values():
            found = recursive_find_key(v, wanted)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = recursive_find_key(v, wanted)
            if found is not None:
                return found
    return None


def infer_health(obj):
    if isinstance(obj, bool):
        return obj
    if not isinstance(obj, dict):
        return None
    for key in ('healthy', 'ok', 'is_healthy', 'health_ok'):
        if isinstance(obj.get(key), bool):
            return obj[key]
    value = obj.get('health') or obj.get('status')
    if isinstance(value, str):
        x = value.lower()
        if x in ('ok', 'healthy', 'up', 'main', 'spare', 'shared'):
            return True
        if x in ('fail', 'failed', 'down', 'unhealthy'):
            return False
    return None


class Watchdog:
    def __init__(self):
        self.cfg = load_json(CONFIG_PATH)
        self.state = load_json(STATE_PATH, {'checks': {}, 'updated_at': None})

    @property
    def iran(self):
        return self.cfg['iran_ssh']

    @property
    def maya(self):
        return self.cfg['maya_ssh']

    def check_iran_and_xhttp(self):
        cmd = r'''set +e
printf 'XUI=%s\n' "$(systemctl is-active x-ui 2>/dev/null)"
printf 'F1_SERVICE=%s\n' "$(systemctl is-active xhttp-dual-f1 2>/dev/null)"
printf 'F2_SERVICE=%s\n' "$(systemctl is-active xhttp-dual-f2 2>/dev/null)"
printf 'F1_CODE=%s\n' "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 --socks5-hostname 127.0.0.1:11818 https://cp.cloudflare.com/generate_204 2>/dev/null)"
printf 'F2_CODE=%s\n' "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 --socks5-hostname 127.0.0.1:11819 https://cp.cloudflare.com/generate_204 2>/dev/null)"
printf 'F1_EGRESS=%s\n' "$(curl -fsS --max-time 10 --connect-timeout 5 --socks5-hostname 127.0.0.1:11818 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')"
printf 'F2_EGRESS=%s\n' "$(curl -fsS --max-time 10 --connect-timeout 5 --socks5-hostname 127.0.0.1:11819 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')"
'''
        try:
            p = ssh_cmd(self.iran, cmd, timeout=35)
        except Exception as exc:
            return {
                'iran': {'ok': False, 'detail': f'ssh exception: {exc}'},
                'f1': {'ok': False, 'detail': 'iran ssh unavailable'},
                'f2': {'ok': False, 'detail': 'iran ssh unavailable'},
            }
        if p.returncode != 0:
            detail = (p.stderr or p.stdout).strip()[-500:]
            return {
                'iran': {'ok': False, 'detail': f'ssh failed: {detail}'},
                'f1': {'ok': False, 'detail': 'iran ssh unavailable'},
                'f2': {'ok': False, 'detail': 'iran ssh unavailable'},
            }
        kv = parse_kv(p.stdout)
        iran_ok = kv.get('XUI') == 'active'
        result = {
            'iran': {'ok': iran_ok, 'detail': f"x-ui={kv.get('XUI', '-')}; ssh=ok"},
        }
        for node in ('f1', 'f2'):
            n = node.upper()
            service = kv.get(f'{n}_SERVICE', '-')
            code = kv.get(f'{n}_CODE', '-')
            egress = kv.get(f'{n}_EGRESS', '-')
            expected = str((self.cfg.get('foreign_nodes') or {}).get(node, {}).get('ip') or '')
            ok = service == 'active' and code in ('200', '204') and bool(egress)
            if expected and egress and egress != expected:
                # NAT/egress IP may intentionally differ, so report mismatch but do not fail the tunnel.
                mismatch = f'; expected-ip={expected}'
            else:
                mismatch = ''
            result[node] = {
                'ok': ok,
                'detail': f'service={service}; http={code}; egress={egress}{mismatch}',
                'egress': egress,
            }
        return result

    def check_foreign_public(self, node):
        nc = (self.cfg.get('foreign_nodes') or {})[node]
        ok, latency, detail = tcp_check(nc['ip'], nc.get('port', 443), timeout=5)
        return {'ok': ok, 'detail': f"public {nc['ip']}:{nc.get('port',443)} {detail}", 'latency_ms': latency}

    def check_maya1(self):
        domain = (self.cfg.get('maya') or {}).get('domain', 'maya1.biya2film.top')
        public_port = int((self.cfg.get('maya') or {}).get('public_port', 443))
        try:
            ips = sorted(set(socket.gethostbyname_ex(domain)[2]))
            dns_ok = bool(ips)
        except Exception as exc:
            ips = []
            dns_ok = False
            dns_err = str(exc)
        tcp_ok, latency, tcp_detail = tcp_check(domain, public_port, timeout=5) if dns_ok else (False, None, 'dns-failed')

        remote_cmd = r'''set +e
printf 'SERVICE=%s\n' "$(systemctl is-active maya-failover.service 2>/dev/null)"
python3 - <<'PY'
import json, os
p='/var/lib/maya-failover/state.json'
try:
    st=os.stat(p)
    print('STATE_AGE=%d' % max(0, int(__import__('time').time()-st.st_mtime)))
    data=json.load(open(p))
    print('STATE_JSON='+json.dumps(data,separators=(',',':')))
except Exception as e:
    print('STATE_AGE=-1')
    print('STATE_ERROR='+str(e).replace('\n',' '))
PY
'''
        remote_ok = False
        service = '-'
        state_age = None
        maya_health = None
        state_detail = ''
        try:
            p = ssh_cmd(self.maya, remote_cmd, timeout=20)
            if p.returncode == 0:
                kv = parse_kv(p.stdout)
                service = kv.get('SERVICE', '-')
                try:
                    state_age = int(kv.get('STATE_AGE', '-1'))
                except Exception:
                    state_age = -1
                raw = kv.get('STATE_JSON')
                if raw:
                    try:
                        state_obj = json.loads(raw)
                        maya1_obj = recursive_find_key(state_obj, 'maya1')
                        maya_health = infer_health(maya1_obj)
                        state_detail = json.dumps(maya1_obj, separators=(',', ':'))[:400] if maya1_obj is not None else 'maya1-key-not-found'
                    except Exception as exc:
                        state_detail = f'state-parse={exc}'
                remote_ok = service == 'active' and state_age is not None and 0 <= state_age <= int((self.cfg.get('maya') or {}).get('max_state_age', 180))
        except Exception as exc:
            state_detail = f'ssh={exc}'

        # Existing Maya controller performs the VLESS/REALITY end-to-end probe; a fresh controller
        # state is therefore treated as the authoritative end-to-end signal when a boolean health
        # value can be inferred. Otherwise DNS+TCP+fresh controller state are reported separately.
        if maya_health is False:
            ok = False
        elif maya_health is True:
            ok = dns_ok and tcp_ok and remote_ok
        else:
            ok = dns_ok and tcp_ok and remote_ok
        return {
            'ok': ok,
            'detail': f'dns={",".join(ips) if ips else dns_err}; tcp={tcp_detail}; maya-service={service}; state-age={state_age}; controller-health={maya_health}; state={state_detail}',
            'dns_ips': ips,
            'latency_ms': latency,
            'controller_health': maya_health,
        }

    def raw_checks(self):
        iran = self.check_iran_and_xhttp()
        out = dict(iran)
        for node in ('f1', 'f2'):
            public = self.check_foreign_public(node)
            out[node]['public_tcp_ok'] = public['ok']
            out[node]['public_detail'] = public['detail']
            out[node]['public_latency_ms'] = public.get('latency_ms')
        out['maya1'] = self.check_maya1()
        return out

    def apply_debounce(self, raw):
        fail_th = int(self.cfg.get('failure_threshold', 3))
        rec_th = int(self.cfg.get('recovery_threshold', 2))
        changed = []
        checks = self.state.setdefault('checks', {})
        for name, res in raw.items():
            s = checks.setdefault(name, {'stable': None, 'fails': 0, 'oks': 0})
            raw_ok = bool(res.get('ok'))
            if raw_ok:
                s['oks'] = int(s.get('oks', 0)) + 1
                s['fails'] = 0
                if s.get('stable') is None or (s.get('stable') is False and s['oks'] >= rec_th):
                    old = s.get('stable')
                    s['stable'] = True
                    if old is not None and old is not True:
                        changed.append((name, True, res.get('detail', '')))
            else:
                s['fails'] = int(s.get('fails', 0)) + 1
                s['oks'] = 0
                if s.get('stable') is None:
                    if s['fails'] >= fail_th:
                        s['stable'] = False
                elif s.get('stable') is True and s['fails'] >= fail_th:
                    s['stable'] = False
                    changed.append((name, False, res.get('detail', '')))
            s['raw_ok'] = raw_ok
            s['detail'] = res.get('detail', '')
            s['last_check'] = now_iso()
            for k, v in res.items():
                if k not in ('ok', 'detail'):
                    s[k] = v
        self.state['updated_at'] = now_iso()
        atomic_json(STATE_PATH, self.state)
        return changed

    def check_once(self, alert=False):
        raw = self.raw_checks()
        changes = self.apply_debounce(raw)
        if alert:
            for name, ok, detail in changes:
                icon = 'RECOVERED' if ok else 'DOWN'
                telegram_send(self.cfg, f'MAYA WATCHDOG {icon}\n{name}\n{detail}\n{now_iso()}')
        return raw

    def status(self):
        raw = self.check_once(alert=False)
        print(f"MAYA WATCHDOG  {now_iso()}")
        print('-' * 72)
        for name in ('iran', 'f1', 'f2', 'maya1'):
            r = raw[name]
            print(f"{name.upper():6} {'OK' if r.get('ok') else 'FAIL':4}  {r.get('detail','')}")

    def daemon(self):
        interval = max(10, int(self.cfg.get('interval', 30)))
        while True:
            try:
                self.check_once(alert=True)
            except Exception as exc:
                print(f'[daemon] {type(exc).__name__}: {exc}', file=sys.stderr, flush=True)
            time.sleep(interval)

    def replace_xhttp(self, node, new_ip):
        if node not in ('f1', 'f2'):
            raise SystemExit('node must be f1 or f2')
        try:
            socket.inet_aton(new_ip)
        except OSError:
            raise SystemExit('NEW_IP must be an IPv4 address')
        check = ssh_cmd(self.iran, 'command -v xhttp-dual-replace-ip', timeout=10)
        if check.returncode != 0:
            raise SystemExit('Iran helper not installed: install xhttp-dual-replace-ip first')
        cmd = f"xhttp-dual-replace-ip {shlex.quote(node)} {shlex.quote(new_ip)}"
        p = ssh_cmd(self.iran, cmd, timeout=60)
        sys.stdout.write(p.stdout)
        sys.stderr.write(p.stderr)
        if p.returncode != 0:
            raise SystemExit(p.returncode)
        self.cfg.setdefault('foreign_nodes', {}).setdefault(node, {})['ip'] = new_ip
        atomic_json(CONFIG_PATH, self.cfg)
        time.sleep(2)
        result = self.check_iran_and_xhttp()[node]
        if not result.get('ok'):
            raise SystemExit(f'remote update completed but health is not OK: {result.get("detail")}')
        telegram_send(self.cfg, f'MAYA WATCHDOG IP REPLACED\n{node}: {new_ip}\n{result.get("detail")}\n{now_iso()}')
        print(f'{node} -> {new_ip} OK')


def main():
    parser = argparse.ArgumentParser(prog='maya-watchdog')
    sub = parser.add_subparsers(dest='cmd', required=True)
    sub.add_parser('status')
    sub.add_parser('check')
    sub.add_parser('daemon')
    rep = sub.add_parser('replace-xhttp')
    rep.add_argument('node', choices=['f1', 'f2'])
    rep.add_argument('new_ip')
    args = parser.parse_args()
    wd = Watchdog()
    if args.cmd == 'status':
        wd.status()
    elif args.cmd == 'check':
        raw = wd.check_once(alert=False)
        print(json.dumps(raw, indent=2, sort_keys=True))
    elif args.cmd == 'daemon':
        wd.daemon()
    elif args.cmd == 'replace-xhttp':
        wd.replace_xhttp(args.node, args.new_ip)


if __name__ == '__main__':
    main()

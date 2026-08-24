#!/usr/bin/env python3
import hmac
import ipaddress
import json
import os
import re
import secrets
import shutil
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CFG_DIR = Path('/etc/dual-stealth-panel')
STATE_FILE = CFG_DIR / 'state.json'
TOKEN_FILE = CFG_DIR / 'token'
HISTORY_FILE = CFG_DIR / 'history.jsonl'
BUNDLE = {'a': Path('/root/dual-stealth-a.env'), 'b': Path('/root/dual-stealth-b.env')}
SERVER_CFG = {'a': Path('/etc/dual-wss-stealth/a-server.toml'), 'b': Path('/etc/dual-wss-stealth/b-server.toml')}
SERVICE = {'a': 'dual-stealth-a-server', 'b': 'dual-stealth-b-server'}
HEALTH_PORT = {'a': 10444, 'b': 20444}
NGINX_SITE = Path('/etc/nginx/sites-available/dual-wss-stealth')
BACKUP_DIR = Path('/root/dual-stealth-panel-backups')
INSTALLER_PIN = '27cbad3ce12b1f4b58d26dc6237eec9c7325f241'
INSTALLER_URL = f'https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/{INSTALLER_PIN}/dual-wss-stealth/install-verified.sh'


def run(args, timeout=20, check=False):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(f"command failed ({p.returncode}): {' '.join(args)}\n{p.stdout[-2000:]}")
    return p.returncode, p.stdout.strip()


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {'foreign_a_ip': '', 'foreign_b_ip': '', 'version': '0.2.0'}


def save_state(state):
    CFG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, indent=2) + '\n')
    os.chmod(tmp, 0o600)
    tmp.replace(STATE_FILE)


def record(event, **data):
    CFG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    row = {'ts': int(time.time()), 'event': event, **data}
    with HISTORY_FILE.open('a') as f:
        f.write(json.dumps(row, separators=(',', ':')) + '\n')
    os.chmod(HISTORY_FILE, 0o600)


def read_token():
    return TOKEN_FILE.read_text().strip()


def health(slot):
    port = HEALTH_PORT[slot]
    rc, out = run(['curl', '-sS', '--max-time', '2', '-o', '/dev/null', '-w', '%{http_code}', f'http://127.0.0.1:{port}/healthz'])
    return out if rc == 0 else '000'


def service_state(name):
    rc, out = run(['systemctl', 'is-active', name])
    return out.strip() if rc == 0 else (out.strip() or 'inactive')


def count_carriers(slot):
    port = '18080' if slot == 'a' else '28080'
    _, out = run(['bash', '-lc', f"ss -Hntp 2>/dev/null | grep '127.0.0.1:{port}' | wc -l"])
    try:
        return int(out.strip())
    except Exception:
        return 0


def status_payload():
    state = load_state()
    return {
        'version': state.get('version', '0.2.0'),
        'a': {'management_ip': state.get('foreign_a_ip', ''), 'health': health('a'), 'service': service_state(SERVICE['a']), 'carriers': count_carriers('a')},
        'b': {'management_ip': state.get('foreign_b_ip', ''), 'health': health('b'), 'service': service_state(SERVICE['b']), 'carriers': count_carriers('b')},
        'shared': {'haproxy': service_state('haproxy'), 'nginx': service_state('nginx'), 'tls': service_state('dual-stealth-tls')},
        'user_sync': {'local_timer': service_state('dual-user-sync.timer'), 'note': 'If user-sync still runs on Foreign A, migrate it to the controller before replacing A.'}
    }


def validate_slot(slot):
    if slot not in ('a', 'b'):
        raise ValueError('invalid slot')
    return slot


def validate_ip(ip):
    obj = ipaddress.ip_address(ip)
    if obj.version != 4:
        raise ValueError('IPv4 required')
    return str(obj)


def stealthctl(action):
    allowed = {'drain-a', 'drain-b', 'activate-a', 'activate-b'}
    if action not in allowed:
        raise ValueError('invalid action')
    return run(['/usr/local/bin/stealthctl', action], timeout=20, check=True)[1]


def parse_bundle(path):
    text = path.read_text()
    def get(name):
        m = re.search(rf"^{name}='([^']*)'$", text, re.M)
        if not m:
            raise RuntimeError(f'{name} missing from {path}')
        return m.group(1)
    return text, {'TOKEN': get('TOKEN'), 'CONTROL_PATH': get('CONTROL_PATH'), 'TUNNEL_PATH': get('TUNNEL_PATH'), 'DOMAIN': get('DOMAIN')}


def backup_files(slot):
    stamp = time.strftime('%Y%m%d-%H%M%S')
    d = BACKUP_DIR / f'{stamp}-slot-{slot}'
    d.mkdir(mode=0o700, parents=True, exist_ok=False)
    for p in (BUNDLE[slot], SERVER_CFG[slot], NGINX_SITE, Path('/etc/haproxy/haproxy.cfg')):
        if p.exists():
            shutil.copy2(p, d / p.name)
    return d


def rotate_slot_secrets(slot):
    slot = validate_slot(slot)
    bpath = BUNDLE[slot]
    spath = SERVER_CFG[slot]
    if not bpath.exists() or not spath.exists() or not NGINX_SITE.exists():
        raise RuntimeError('slot files missing')
    backup = backup_files(slot)
    btext, old = parse_bundle(bpath)
    new_token = secrets.token_hex(32)
    new_control = '/assets/v4/' + secrets.token_hex(16)
    new_tunnel = '/api/socket/' + secrets.token_hex(16)

    stext = spath.read_text()
    replacements = [
        (rf'^token = ".*"$', f'token = "{new_token}"'),
        (rf'^ws_control_path = ".*"$', f'ws_control_path = "{new_control}"'),
        (rf'^ws_tunnel_path = ".*"$', f'ws_tunnel_path = "{new_tunnel}"'),
    ]
    for pat, repl in replacements:
        stext, n = re.subn(pat, repl, stext, count=1, flags=re.M)
        if n != 1:
            raise RuntimeError(f'failed updating {pat}')

    btext = re.sub(r"^TOKEN='[^']*'$", f"TOKEN='{new_token}'", btext, count=1, flags=re.M)
    btext = re.sub(r"^CONTROL_PATH='[^']*'$", f"CONTROL_PATH='{new_control}'", btext, count=1, flags=re.M)
    btext = re.sub(r"^TUNNEL_PATH='[^']*'$", f"TUNNEL_PATH='{new_tunnel}'", btext, count=1, flags=re.M)

    ntext = NGINX_SITE.read_text()
    if old['CONTROL_PATH'] not in ntext or old['TUNNEL_PATH'] not in ntext:
        raise RuntimeError('old slot paths not found in nginx config')
    ntext = ntext.replace(old['CONTROL_PATH'], new_control).replace(old['TUNNEL_PATH'], new_tunnel)

    for path, content, mode in ((spath, stext, 0o600), (bpath, btext, 0o600), (NGINX_SITE, ntext, 0o644)):
        tmp = path.with_suffix(path.suffix + '.paneltmp')
        tmp.write_text(content)
        os.chmod(tmp, mode)
        tmp.replace(path)
    rc, out = run(['nginx', '-t'])
    if rc != 0:
        raise RuntimeError('nginx validation failed after rotation: ' + out)
    run(['systemctl', 'reload', 'nginx'], check=True)
    run(['systemctl', 'restart', SERVICE[slot]], check=True)
    record('rotate_slot_secrets', slot=slot, backup=str(backup))
    return {'backup': str(backup), 'bundle': str(bpath), 'domain': old['DOMAIN']}


def prepare_replace(slot, new_ip, rotate=True):
    slot = validate_slot(slot)
    new_ip = validate_ip(new_ip)
    stealthctl('drain-' + slot)
    if rotate:
        details = rotate_slot_secrets(slot)
    else:
        details = {'bundle': str(BUNDLE[slot]), 'domain': parse_bundle(BUNDLE[slot])[1]['DOMAIN'], 'backup': ''}
        run(['systemctl', 'restart', SERVICE[slot]], check=True)
    state = load_state()
    key = 'foreign_a_ip' if slot == 'a' else 'foreign_b_ip'
    old_ip = state.get(key, '')
    state[key] = new_ip
    save_state(state)
    bundle_name = BUNDLE[slot].name
    commands = [
        f"scp {BUNDLE[slot]} root@{new_ip}:/root/{bundle_name}",
        f"ssh root@{new_ip} 'curl -fL {INSTALLER_URL} -o /root/install-dual-wss-verified.sh && bash /root/install-dual-wss-verified.sh --role foreign --bundle /root/{bundle_name}'",
    ]
    record('prepare_replace', slot=slot, old_ip=old_ip, new_ip=new_ip, rotate=bool(rotate))
    return {'slot': slot, 'old_ip': old_ip, 'new_ip': new_ip, 'rotated': bool(rotate), 'commands': commands, **details}


def activate_replacement(slot):
    slot = validate_slot(slot)
    code = health(slot)
    if code != '200':
        raise RuntimeError(f'slot {slot.upper()} health is {code}; refusing activation')
    out = stealthctl('activate-' + slot)
    record('activate_replacement', slot=slot)
    return {'health': code, 'output': out}


HTML = r'''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aegis Control</title><style>
:root{font-family:Inter,ui-sans-serif,system-ui;background:#07111f;color:#e8f0ff}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:radial-gradient(circle at 20% 10%,#153252 0,transparent 35%),#07111f}.wrap{max-width:1100px;margin:auto;padding:34px}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:22px}.brand{font-size:24px;font-weight:750}.muted{color:#91a4bf}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:16px}.card{background:rgba(255,255,255,.065);border:1px solid rgba(255,255,255,.10);backdrop-filter:blur(16px);border-radius:20px;padding:20px;box-shadow:0 16px 50px rgba(0,0,0,.18)}.row{display:flex;justify-content:space-between;gap:14px;align-items:center}.dot{width:10px;height:10px;border-radius:50%;display:inline-block;margin-right:7px}.ok{background:#52d273}.bad{background:#ff667a}.pill{padding:6px 10px;border-radius:999px;background:rgba(255,255,255,.07);font-size:13px}button{border:0;border-radius:12px;padding:10px 13px;background:#e8f0ff;color:#07111f;font-weight:700;cursor:pointer}button.alt{background:rgba(255,255,255,.09);color:#e8f0ff}input{width:100%;background:rgba(0,0,0,.18);border:1px solid rgba(255,255,255,.12);color:#fff;padding:11px;border-radius:11px;margin:7px 0 12px}.actions{display:flex;flex-wrap:wrap;gap:8px;margin-top:16px}pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.24);padding:12px;border-radius:12px;min-height:46px}.modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.65);align-items:center;justify-content:center}.modal .card{width:min(560px,92vw)}h3{margin:0 0 8px}</style></head>
<body><div class="wrap"><div class="top"><div><div class="brand">Aegis Control</div><div class="muted">Dual Foreign production control plane</div></div><button class="alt" onclick="load()">Refresh</button></div><div class="grid" id="grid"></div><div class="card" style="margin-top:16px"><div class="row"><b>Event / command output</b><span class="muted">loopback-only panel</span></div><pre id="out">Ready.</pre></div></div>
<div class="modal" id="replace"><div class="card"><h3 id="rtitle">Replace slot</h3><div class="muted">The slot is drained first. Secret rotation invalidates the retired node.</div><input id="rip" placeholder="New Foreign IPv4"><label><input style="width:auto" type="checkbox" id="rotate" checked> rotate slot token and paths</label><div class="actions"><button onclick="doReplace()">Prepare replacement</button><button class="alt" onclick="closeReplace()">Cancel</button></div></div></div>
<script>
let token=localStorage.getItem('aegisToken')||prompt('Panel token'); if(token)localStorage.setItem('aegisToken',token); let replaceSlot='a';
async function api(path,opt={}){opt.headers={...(opt.headers||{}),'Authorization':'Bearer '+token,'Content-Type':'application/json'};let r=await fetch(path,opt);let t=await r.text();let j;try{j=JSON.parse(t)}catch{j={error:t}}if(!r.ok)throw Error(j.error||r.statusText);return j}
function badge(x){return `<span class="pill"><span class="dot ${x==='200'||x==='active'?'ok':'bad'}"></span>${x}</span>`}
async function load(){try{let s=await api('/api/status');let cards=['a','b'].map(k=>{let x=s[k];return `<div class="card"><div class="row"><h3>Foreign ${k.toUpperCase()}</h3>${badge(x.health)}</div><div class="muted">${x.management_ip||'management IP not recorded'}</div><div style="margin-top:14px" class="row"><span>tunnel service</span>${badge(x.service)}</div><div class="row" style="margin-top:8px"><span>carrier sockets</span><span class="pill">${x.carriers}</span></div><div class="actions"><button class="alt" onclick="action('drain-${k}')">Drain</button><button onclick="safeActivate('${k}')">Activate</button><button class="alt" onclick="openReplace('${k}')">Replace server</button></div></div>`}).join('');cards+=`<div class="card"><h3>Shared services</h3><div class="row"><span>HAProxy</span>${badge(s.shared.haproxy)}</div><div class="row" style="margin-top:8px"><span>Nginx</span>${badge(s.shared.nginx)}</div><div class="row" style="margin-top:8px"><span>TLS</span>${badge(s.shared.tls)}</div><div class="muted" style="margin-top:14px">User sync timer on controller: ${s.user_sync.local_timer}</div></div>`;document.getElementById('grid').innerHTML=cards}catch(e){document.getElementById('out').textContent=e}}
async function action(a){try{let j=await api('/api/action',{method:'POST',body:JSON.stringify({action:a})});document.getElementById('out').textContent=j.output||JSON.stringify(j,null,2);load()}catch(e){document.getElementById('out').textContent=e}}
async function safeActivate(s){try{let j=await api('/api/replace/activate',{method:'POST',body:JSON.stringify({slot:s})});document.getElementById('out').textContent=JSON.stringify(j,null,2);load()}catch(e){document.getElementById('out').textContent=e}}
function openReplace(s){replaceSlot=s;document.getElementById('rtitle').textContent='Replace Foreign '+s.toUpperCase();document.getElementById('replace').style.display='flex'}function closeReplace(){document.getElementById('replace').style.display='none'}
async function doReplace(){try{let j=await api('/api/replace/prepare',{method:'POST',body:JSON.stringify({slot:replaceSlot,new_ip:document.getElementById('rip').value,rotate:document.getElementById('rotate').checked})});closeReplace();document.getElementById('out').textContent='Slot drained. Run on Iran:\n\n'+j.commands.join('\n\n')+'\n\nAfter health becomes 200, click Activate.';load()}catch(e){document.getElementById('out').textContent=e}}
load();setInterval(load,10000);
</script></body></html>'''


class Handler(BaseHTTPRequestHandler):
    server_version = 'AegisPanel/0.2'
    def log_message(self, fmt, *args):
        return
    def auth(self):
        token = self.headers.get('Authorization', '').removeprefix('Bearer ').strip()
        return token and hmac.compare_digest(token, read_token())
    def send_json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == '/':
            b = HTML.encode(); self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b); return
        if not self.auth(): self.send_json({'error':'unauthorized'},401); return
        if self.path == '/api/status': self.send_json(status_payload()); return
        self.send_json({'error':'not found'},404)
    def do_POST(self):
        if not self.auth(): self.send_json({'error':'unauthorized'},401); return
        try:
            n = min(int(self.headers.get('Content-Length','0')), 16384)
            body = json.loads(self.rfile.read(n) or b'{}')
            if self.path == '/api/action':
                action = str(body.get('action',''))
                if action not in {'drain-a','drain-b','activate-a','activate-b'}: raise ValueError('invalid action')
                out = stealthctl(action); record('panel_action', action=action); self.send_json({'ok':True,'output':out}); return
            if self.path == '/api/replace/prepare':
                self.send_json(prepare_replace(str(body.get('slot','')), str(body.get('new_ip','')), bool(body.get('rotate',True)))); return
            if self.path == '/api/replace/activate':
                self.send_json(activate_replacement(str(body.get('slot','')))); return
            self.send_json({'error':'not found'},404)
        except Exception as e:
            self.send_json({'error':str(e)},400)


def main():
    bind = os.environ.get('AEGIS_PANEL_BIND','127.0.0.1')
    port = int(os.environ.get('AEGIS_PANEL_PORT','8787'))
    if not TOKEN_FILE.exists():
        raise SystemExit('panel token missing')
    srv = ThreadingHTTPServer((bind,port), Handler)
    print(f'Aegis panel listening on http://{bind}:{port}')
    srv.serve_forever()

if __name__ == '__main__': main()

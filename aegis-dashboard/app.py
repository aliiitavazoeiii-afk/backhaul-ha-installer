#!/usr/bin/env python3
import json,os,secrets,threading
from http import cookies
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs,urlparse
import provision as p

PORT=8787; UI=Path('/opt/aegis-dashboard/ui.html').read_text()
PUBLIC_ORIGIN=os.getenv('AEGIS_PUBLIC_ORIGIN','').strip().rstrip('/')
ALLOWED_ORIGINS={f'http://127.0.0.1:{PORT}',f'http://localhost:{PORT}'}
if PUBLIC_ORIGIN:
    ALLOWED_ORIGINS.add(PUBLIC_ORIGIN)
SECURE_COOKIE='; Secure' if PUBLIC_ORIGIN.startswith('https://') else ''

class H(BaseHTTPRequestHandler):
    server_version='AegisDashboard/1.0'
    def log_message(self,*a): pass
    def auth(self):
        c=cookies.SimpleCookie()
        try: c.load(self.headers.get('Cookie',''))
        except Exception: return False
        return bool(c.get('aegis_token') and secrets.compare_digest(c['aegis_token'].value,p.TOKEN))
    def js(self,code,obj):
        b=json.dumps(obj,ensure_ascii=False).encode(); self.send_response(code); self.send_header('Content-Type','application/json; charset=utf-8'); self.send_header('Content-Length',str(len(b))); self.send_header('Cache-Control','no-store'); self.end_headers(); self.wfile.write(b)
    def body(self):
        n=int(self.headers.get('Content-Length','0') or 0)
        if n<1 or n>16384: raise ValueError('invalid request size')
        return json.loads(self.rfile.read(n))
    def do_GET(self):
        u=urlparse(self.path); q=parse_qs(u.query)
        if u.path=='/' and q.get('token') and secrets.compare_digest(q['token'][0],p.TOKEN):
            self.send_response(302); self.send_header('Set-Cookie',f'aegis_token={p.TOKEN}; Path=/; HttpOnly; SameSite=Strict{SECURE_COOKIE}'); self.send_header('Location','/'); self.send_header('Cache-Control','no-store'); self.end_headers(); return
        if not self.auth(): return self.js(403,{'error':'unauthorized'})
        if u.path=='/':
            b=UI.encode(); self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.send_header('Content-Length',str(len(b))); self.send_header('Cache-Control','no-store'); self.end_headers(); self.wfile.write(b); return
        if u.path=='/api/status':
            s=p.load_state(); pub=p.SSH_KEY.with_suffix('.pub').read_text().strip() if p.SSH_KEY.with_suffix('.pub').exists() else ''; txt=p.LOG_FILE.read_text(errors='replace')[-30000:] if p.LOG_FILE.exists() else ''
            return self.js(200,{'state':s,'health':p.live_health(s.get('config',{})),'pubkey':pub,'log':txt})
        self.js(404,{'error':'not found'})
    def do_POST(self):
        if not self.auth(): return self.js(403,{'error':'unauthorized'})
        origin=self.headers.get('Origin','').rstrip('/')
        if origin and origin not in ALLOWED_ORIGINS: return self.js(403,{'error':'origin rejected'})
        try:
            cfg=p.validate_config(self.body()); s=p.load_state(); s['config']=cfg; p.save_state(s)
            if self.path=='/api/ssh-check': p.ensure_ssh_key(); return self.js(200,{'primary':p.ssh_ready(cfg['primary_ip']),'backup':p.ssh_ready(cfg['backup_ip'])})
            if self.path=='/api/deploy':
                if p.job_lock.locked(): return self.js(409,{'error':'another job is running'})
                threading.Thread(target=p.deploy,args=(cfg,),daemon=True).start(); return self.js(202,{'ok':True})
            if self.path=='/api/template-refresh':
                if p.job_lock.locked(): return self.js(409,{'error':'another job is running'})
                threading.Thread(target=template_worker,args=(cfg,),daemon=True).start(); return self.js(202,{'ok':True})
            return self.js(404,{'error':'not found'})
        except Exception as e: return self.js(400,{'error':str(e)})
def template_worker(cfg):
    if not p.job_lock.acquire(False): return
    try:
        s=p.load_state(); s['job']={'status':'running','step':'Refreshing golden template','started_at':p.now(),'ended_at':None,'error':None}; p.save_state(s); p.capture_template(cfg['primary_ip']); p.set_job('success','Golden template refreshed')
    except Exception as e: p.log(f'ERROR: template refresh: {e}'); p.set_job('error','Template refresh failed',str(e))
    finally: p.job_lock.release()
def main():
    p.ensure_ssh_key(); p.log(f'Aegis Dashboard v{p.APP_VERSION} listening on 127.0.0.1:{PORT}'); s=ThreadingHTTPServer(('127.0.0.1',PORT),H); s.daemon_threads=True; s.serve_forever()
if __name__=='__main__': main()

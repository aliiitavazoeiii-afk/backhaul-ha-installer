from __future__ import annotations

import ipaddress, json, os, re, secrets, shlex, socket, sqlite3, subprocess, threading
from datetime import datetime, timezone
from pathlib import Path

APP_VERSION="1.0.0"
ROOT=Path('/var/lib/aegis-dashboard'); ETC=Path('/etc/aegis-dashboard')
STATE_FILE=ROOT/'state.json'; LOG_FILE=ROOT/'provision.log'; TEMPLATE_FILE=ROOT/'x-ui-template.db'; TOKEN_FILE=ETC/'token'
SSH_KEY=Path('/root/.ssh/id_ed25519')
REMOTE_XUI_INSTALLER=Path('/opt/aegis-dashboard/remote/install-3xui-2.9.4.sh')
AEGIS_INSTALLER=Path('/opt/aegis-dashboard/vendor/install-aegis-single.sh')
BACKUP_INSTALLER=Path('/opt/aegis-dashboard/vendor/add-direct-backup.sh')
SSH_OPTS=['-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=2','-o','StrictHostKeyChecking=accept-new']
DOMAIN_RE=re.compile(r'^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$')
ROOT.mkdir(parents=True,exist_ok=True); ETC.mkdir(parents=True,exist_ok=True)
if not TOKEN_FILE.exists(): TOKEN_FILE.write_text(secrets.token_urlsafe(32)+'\n'); os.chmod(TOKEN_FILE,0o600)
TOKEN=TOKEN_FILE.read_text().strip(); state_lock=threading.RLock(); job_lock=threading.Lock()

def now(): return datetime.now(timezone.utc).isoformat(timespec='seconds')
def load_state():
    with state_lock:
        if not STATE_FILE.exists(): return {'version':APP_VERSION,'job':{'status':'idle','step':'','started_at':None,'ended_at':None,'error':None},'config':{'domain':'','iran_ip':'','primary_ip':'','backup_ip':''},'last_success':None}
        try: return json.loads(STATE_FILE.read_text())
        except Exception: return {'version':APP_VERSION,'job':{'status':'error','error':'state file unreadable'},'config':{}}
def save_state(s):
    with state_lock:
        t=STATE_FILE.with_suffix('.tmp'); t.write_text(json.dumps(s,ensure_ascii=False,indent=2)+'\n'); os.chmod(t,0o600); t.replace(STATE_FILE)
def log(msg):
    line=f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    with state_lock:
        with LOG_FILE.open('a',encoding='utf-8') as f: f.write(line+'\n')
    print(line,flush=True)
def set_job(status,step='',error=None):
    s=load_state(); j=s.setdefault('job',{}); j.update(status=status,step=step,error=error)
    if status=='running' and not j.get('started_at'): j['started_at']=now(); j['ended_at']=None
    if status in {'success','error'}: j['ended_at']=now()
    save_state(s)
    if step: log(f'{status.upper()}: {step}')
def validate_config(d):
    def ip(v):
        x=ipaddress.ip_address(str(v).strip())
        if x.version!=4: raise ValueError('only IPv4 is supported')
        return str(x)
    domain=str(d.get('domain','')).strip().lower().rstrip('.')
    if not DOMAIN_RE.fullmatch(domain): raise ValueError('invalid domain')
    c={'domain':domain,'iran_ip':ip(d.get('iran_ip','')),'primary_ip':ip(d.get('primary_ip','')),'backup_ip':ip(d.get('backup_ip',''))}
    if len({c['iran_ip'],c['primary_ip'],c['backup_ip']})!=3: raise ValueError('Iran, primary and backup IPs must be different')
    return c

def run(cmd,timeout=180,check=True):
    log('$ '+' '.join(shlex.quote(str(x)) for x in cmd)); cp=subprocess.run(cmd,text=True,capture_output=True,timeout=timeout)
    for x in cp.stdout.rstrip().splitlines(): log('  '+x)
    for x in cp.stderr.rstrip().splitlines(): log('  ! '+x)
    if check and cp.returncode: raise RuntimeError(f'command failed ({cp.returncode}): {cmd[0]}')
    return cp
def ssh(ip,command,timeout=180,check=True): return run(['ssh',*SSH_OPTS,f'root@{ip}',command],timeout,check)
def scp_to(ip,local,remote,timeout=180): run(['scp',*SSH_OPTS,str(local),f'root@{ip}:{remote}'],timeout)
def scp_from(ip,remote,local,timeout=180): run(['scp',*SSH_OPTS,f'root@{ip}:{remote}',str(local)],timeout)
def ssh_silent(ip,command,timeout=6): return subprocess.run(['ssh',*SSH_OPTS,f'root@{ip}',command],text=True,capture_output=True,timeout=timeout)
def ssh_ready(ip):
    try: return ssh_silent(ip,'true',5).returncode==0
    except Exception: return False
def dns_ready(domain,iran):
    try: ips=sorted({x[4][0] for x in socket.getaddrinfo(domain,None,socket.AF_INET,socket.SOCK_STREAM)})
    except socket.gaierror: ips=[]
    return iran in ips,ips
def sqlite_ok(p):
    if not p.exists() or p.stat().st_size<4096: return False
    try:
        c=sqlite3.connect(f'file:{p}?mode=ro',uri=True); r=c.execute('PRAGMA quick_check').fetchone(); c.close(); return bool(r and r[0]=='ok')
    except sqlite3.Error: return False
def ensure_ssh_key():
    pub=SSH_KEY.with_suffix('.pub')
    SSH_KEY.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    if SSH_KEY.exists():
        if pub.exists(): return
        cp=subprocess.run(['ssh-keygen','-y','-f',str(SSH_KEY)],text=True,capture_output=True,timeout=20)
        if cp.returncode or not cp.stdout.strip(): raise RuntimeError('existing SSH private key is unreadable; public key could not be derived')
        pub.write_text(cp.stdout.strip()+'\n'); os.chmod(pub,0o644); return
    if pub.exists(): pub.rename(pub.with_name(pub.name+'.orphan-'+datetime.now().strftime('%Y%m%d%H%M%S')))
    run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(SSH_KEY)],20)
def capture_template(primary):
    set_job('running','Capturing golden 3x-ui template from primary')
    if not ssh_ready(primary): raise RuntimeError(f'SSH key access to primary {primary} is not ready')
    cmd="set -Eeuo pipefail; command -v sqlite3 >/dev/null || (apt-get update -y >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y sqlite3 >/dev/null); test -s /etc/x-ui/x-ui.db; rm -f /tmp/aegis-golden.db; sqlite3 /etc/x-ui/x-ui.db \".backup '/tmp/aegis-golden.db'\"; sqlite3 /tmp/aegis-golden.db 'PRAGMA quick_check;' | grep -qx ok"
    ssh(primary,cmd,120); tmp=TEMPLATE_FILE.with_suffix('.new'); scp_from(primary,'/tmp/aegis-golden.db',tmp); ssh(primary,'rm -f /tmp/aegis-golden.db',20,False)
    if not sqlite_ok(tmp): tmp.unlink(missing_ok=True); raise RuntimeError('captured golden database failed SQLite quick_check')
    os.chmod(tmp,0o600); tmp.replace(TEMPLATE_FILE); log(f'Golden template saved: {TEMPLATE_FILE} ({TEMPLATE_FILE.stat().st_size} bytes)')
def install_xui(ip,role):
    probe=("test -x /usr/local/x-ui/x-ui && "
           "test -s /etc/x-ui/x-ui.db && "
           "test \"$(/usr/local/x-ui/x-ui -v 2>/dev/null | tr -d '[:space:]')\" = '2.9.4' && "
           "systemctl is-active --quiet x-ui && "
           "timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' >/dev/null 2>&1")
    if ssh(ip,probe,20,False).returncode==0:
        log(f'3x-ui v2.9.4 + Xray :443 already healthy on {role} {ip}; preserving existing DB/panel settings')
        return
    set_job('running',f'Installing verified 3x-ui v2.9.4 on {role} {ip}')
    scp_to(ip,REMOTE_XUI_INSTALLER,'/root/install-3xui-2.9.4.sh')
    scp_to(ip,TEMPLATE_FILE,'/root/aegis-xui-template.db')
    cp=ssh(ip,'chmod 700 /root/install-3xui-2.9.4.sh && bash /root/install-3xui-2.9.4.sh',420,False)
    if cp.returncode==20: raise RuntimeError(f'3x-ui installed on {ip}, but golden template did not provide Xray 127.0.0.1:443')
    if cp.returncode: raise RuntimeError(f'3x-ui v2.9.4 install failed on {ip}')

def deploy(cfg):
    if not job_lock.acquire(False): return
    try:
        s=load_state(); s['config']=cfg; s['job']={'status':'running','step':'Starting preflight','started_at':now(),'ended_at':None,'error':None}; save_state(s); LOG_FILE.write_text('')
        log(f"Topology: Iran={cfg['iran_ip']} primary={cfg['primary_ip']} backup={cfg['backup_ip']} domain={cfg['domain']}")
        set_job('running','Preflight: DNS'); ok,ips=dns_ready(cfg['domain'],cfg['iran_ip'])
        if not ok: raise RuntimeError(f"{cfg['domain']} resolves to {ips or 'nothing'}, expected {cfg['iran_ip']}")
        set_job('running','Preflight: SSH access'); ensure_ssh_key()
        for k in ('primary_ip','backup_ip'):
            if not ssh_ready(cfg[k]): raise RuntimeError(f"SSH key access to {cfg[k]} is not ready; add the dashboard public key once")
        if not sqlite_ok(TEMPLATE_FILE): log('No valid golden template stored; capturing from current primary'); capture_template(cfg['primary_ip'])
        else: log('Using stored golden 3x-ui template')
        install_xui(cfg['primary_ip'],'PRIMARY'); install_xui(cfg['backup_ip'],'BACKUP')
        set_job('running','Installing/updating Aegis Iran gateway'); run(['bash',str(AEGIS_INSTALLER),'--role','iran','--iran-ip',cfg['iran_ip'],'--domain',cfg['domain']],420)
        bundle=Path('/root/aegis-primary.env')
        if not bundle.exists(): raise RuntimeError('Aegis primary bundle was not created on Iran')
        set_job('running','Installing Aegis primary client'); scp_to(cfg['primary_ip'],AEGIS_INSTALLER,'/root/install-aegis-single.sh'); scp_to(cfg['primary_ip'],bundle,'/root/aegis-primary.env'); ssh(cfg['primary_ip'],'chmod 700 /root/install-aegis-single.sh && bash /root/install-aegis-single.sh --role foreign --bundle /root/aegis-primary.env',420)
        set_job('running','Installing direct backup relay'); scp_to(cfg['backup_ip'],BACKUP_INSTALLER,'/root/add-direct-backup.sh'); ssh(cfg['backup_ip'],f"chmod 700 /root/add-direct-backup.sh && bash /root/add-direct-backup.sh --role foreign --iran-ip {cfg['iran_ip']} --backup-ip {cfg['backup_ip']}",180)
        set_job('running','Adding health-gated backup to Iran HAProxy'); run(['bash',str(BACKUP_INSTALLER),'--role','iran','--iran-ip',cfg['iran_ip'],'--backup-ip',cfg['backup_ip']],180)
        set_job('running','Final end-to-end validation'); cp=run(['aegisctl','status'],30)
        if 'primary-ready: UP' not in cp.stdout: raise RuntimeError('Aegis primary readiness is not UP')
        if run(['bash','-lc',f"timeout 4 bash -c 'exec 3<>/dev/tcp/{cfg['backup_ip']}/443'"],10,False).returncode: raise RuntimeError('direct backup is not reachable from Iran')
        for ip in (cfg['primary_ip'],cfg['backup_ip']):
            cp=ssh(ip,'systemctl is-active x-ui',20,False)
            if cp.returncode or 'active' not in cp.stdout: raise RuntimeError(f'3x-ui is not active on {ip}')
        s=load_state(); s['last_success']=now(); s['job']={'status':'success','step':'Production topology verified','started_at':s.get('job',{}).get('started_at'),'ended_at':now(),'error':None}; save_state(s); log('SUCCESS: Aegis primary + direct backup + 3x-ui v2.9.4 verified')
    except Exception as e: log(f'ERROR: {e}'); set_job('error','Provisioning stopped safely',str(e))
    finally: job_lock.release()
def live_health(cfg):
    out={'iran':{},'primary':{},'backup':{},'template':{'ready':sqlite_ok(TEMPLATE_FILE)}}
    try:
        cp=subprocess.run(['aegisctl','status'],text=True,capture_output=True,timeout=5); t=cp.stdout; out['iran']={'aegis':'aegis-server: active' in t,'haproxy':'haproxy:      active' in t,'primary_ready':'primary-ready: UP' in t}
    except Exception: pass
    for name,key in (('primary','primary_ip'),('backup','backup_ip')):
        ip=cfg.get(key) if cfg else None
        if not ip: continue
        out[name]['ssh']=ssh_ready(ip)
        if out[name]['ssh']:
            try:
                cp=ssh_silent(ip,"printf 'xui='; systemctl is-active x-ui 2>/dev/null || true; printf 'xray='; timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/443' >/dev/null 2>&1 && echo up || echo down",6); out[name]['xui']='xui=active' in cp.stdout; out[name]['xray']='xray=up' in cp.stdout
            except Exception: pass
    return out

#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/xray-telegram-monitor
CFG_DIR=$APP_DIR/configs
STATE_DIR=$APP_DIR/state
XRAY_CFG=/usr/local/etc/xray/monitor.json
SERVICE=/etc/systemd/system/xray-telegram-monitor.service
CORE_SERVICE=/etc/systemd/system/xray-monitor-core.service
ENV_FILE=$APP_DIR/monitor.env
PY_FILE=$APP_DIR/monitor.py

if [[ $EUID -ne 0 ]]; then
  echo 'Run this installer as root: sudo bash install.sh'
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo 'This installer requires a systemd-based Linux distribution.'
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl ca-certificates python3
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl ca-certificates python3
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl ca-certificates python3
else
  echo 'Unsupported package manager. Install curl, ca-certificates and python3 first.'
  exit 1
fi

if ! command -v xray >/dev/null 2>&1; then
  echo 'Installing Xray...'
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  systemctl disable --now xray.service >/dev/null 2>&1 || true
fi

mkdir -p "$APP_DIR" "$CFG_DIR" "$STATE_DIR" "$(dirname "$XRAY_CFG")"
chmod 700 "$APP_DIR" "$CFG_DIR" "$STATE_DIR"

echo
read -rp 'How many VLESS configs do you want to monitor? ' COUNT
[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid number.'; exit 1; }

CONFIG_LIST=$APP_DIR/vless.list
: > "$CONFIG_LIST"
chmod 600 "$CONFIG_LIST"
for ((i=1;i<=COUNT;i++)); do
  echo
  read -rp "Paste VLESS config #$i: " URI
  [[ "$URI" == vless://* ]] || { echo 'Only vless:// links are supported.'; exit 1; }
  printf '%s\n' "$URI" >> "$CONFIG_LIST"
done

echo
read -rp 'Telegram Bot Token: ' TG_TOKEN
[[ -n "$TG_TOKEN" ]] || { echo 'Bot token is required.'; exit 1; }
echo 'Now send any message to your Telegram bot, then press Enter here.'
read -r

UPDATES=$(curl -fsS "https://api.telegram.org/bot${TG_TOKEN}/getUpdates") || { echo 'Cannot reach Telegram API or token is invalid.'; exit 1; }
TG_CHAT_ID=$(python3 - "$UPDATES" <<'PY'
import json,sys
j=json.loads(sys.argv[1])
items=j.get('result') or []
for u in reversed(items):
    m=u.get('message') or u.get('channel_post') or u.get('edited_message') or {}
    c=m.get('chat') or {}
    if 'id' in c:
        print(c['id']); break
PY
)
[[ -n "$TG_CHAT_ID" ]] || { echo 'Could not detect chat ID. Make sure you sent a message to the bot.'; exit 1; }

echo "Detected Telegram chat ID: $TG_CHAT_ID"

python3 - "$CONFIG_LIST" "$XRAY_CFG" <<'PY'
import json,sys,urllib.parse,re
src,out=sys.argv[1:3]
uris=[x.strip() for x in open(src,encoding='utf-8') if x.strip()]
inbounds=[]; outbounds=[]; rules=[]
base=21080
names=[]

def q1(q,k,d=''):
    return (q.get(k) or [d])[0]

def b(v):
    return str(v).lower() in ('1','true','yes','on')

for i,uri in enumerate(uris):
    u=urllib.parse.urlsplit(uri)
    q=urllib.parse.parse_qs(u.query, keep_blank_values=True)
    name=urllib.parse.unquote(u.fragment or f'Server {i+1}')
    name=re.sub(r'[\r\n\t]+',' ',name).strip() or f'Server {i+1}'
    names.append(name)
    address=u.hostname
    port=u.port or 443
    uuid=urllib.parse.unquote(u.username or '')
    if not address or not uuid:
        raise SystemExit(f'Invalid VLESS config #{i+1}')
    tag=f'out-{i+1}'
    in_tag=f'in-{i+1}'
    transport=q1(q,'type','tcp').lower()
    if transport == 'tcp': transport='raw'
    security=q1(q,'security','none').lower()
    user={'id':uuid,'encryption':q1(q,'encryption','none')}
    flow=q1(q,'flow','')
    if flow: user['flow']=flow
    ob={
      'tag':tag,
      'protocol':'vless',
      'settings':{'vnext':[{'address':address,'port':port,'users':[user]}]},
      'streamSettings':{'network':transport,'security':security}
    }
    ss=ob['streamSettings']
    if transport=='raw':
        header_type=q1(q,'headerType','none')
        ss['rawSettings']={'header':{'type':header_type}}
    elif transport=='grpc':
        ss['grpcSettings']={'serviceName':q1(q,'serviceName',q1(q,'service','')),'multiMode':b(q1(q,'mode','false'))}
    elif transport=='ws':
        ws={'path':q1(q,'path','/')}
        host=q1(q,'host','')
        if host: ws['headers']={'Host':host}
        ss['wsSettings']=ws
    elif transport=='xhttp':
        xs={}
        path=q1(q,'path','')
        host=q1(q,'host','')
        mode=q1(q,'mode','')
        if path: xs['path']=path
        if host: xs['host']=host
        if mode: xs['mode']=mode
        ss['xhttpSettings']=xs
    else:
        raise SystemExit(f'Unsupported transport in config #{i+1}: {transport}')
    if security=='reality':
        rs={
          'serverName':q1(q,'sni',''),
          'fingerprint':q1(q,'fp','chrome'),
          'password':q1(q,'pbk',''),
          'shortId':q1(q,'sid',''),
          'spiderX':q1(q,'spx','')
        }
        if not rs['password']:
            raise SystemExit(f'Missing pbk in REALITY config #{i+1}')
        ss['realitySettings']=rs
    elif security=='tls':
        ts={'serverName':q1(q,'sni',q1(q,'host',address)),'fingerprint':q1(q,'fp','chrome')}
        alpn=q1(q,'alpn','')
        if alpn: ts['alpn']=[x for x in alpn.split(',') if x]
        if q1(q,'allowInsecure',''): ts['allowInsecure']=b(q1(q,'allowInsecure'))
        ss['tlsSettings']=ts
    elif security not in ('none',''):
        raise SystemExit(f'Unsupported security in config #{i+1}: {security}')
    inbounds.append({'tag':in_tag,'listen':'127.0.0.1','port':base+i,'protocol':'socks','settings':{'udp':False}})
    outbounds.append(ob)
    rules.append({'type':'field','inboundTag':[in_tag],'outboundTag':tag})

cfg={'log':{'loglevel':'warning'},'inbounds':inbounds,'outbounds':outbounds+[{'protocol':'freedom','tag':'direct'}], 'routing':{'domainStrategy':'AsIs','rules':rules}}
with open(out,'w',encoding='utf-8') as f: json.dump(cfg,f,ensure_ascii=False,indent=2)
with open('/opt/xray-telegram-monitor/names.json','w',encoding='utf-8') as f: json.dump(names,f,ensure_ascii=False)
PY

/usr/local/bin/xray run -test -config "$XRAY_CFG"

cat > "$ENV_FILE" <<EOFENV
TG_TOKEN=$TG_TOKEN
TG_CHAT_ID=$TG_CHAT_ID
CHECK_INTERVAL=30
FAIL_THRESHOLD=3
REQUEST_TIMEOUT=12
BASE_PORT=21080
EOFENV
chmod 600 "$ENV_FILE"

cat > "$PY_FILE" <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, time, urllib.parse, urllib.request
from pathlib import Path

APP=Path('/opt/xray-telegram-monitor')
STATE=APP/'state'
NAMES=json.loads((APP/'names.json').read_text(encoding='utf-8'))
TOKEN=os.environ['TG_TOKEN']; CHAT=os.environ['TG_CHAT_ID']
INTERVAL=int(os.getenv('CHECK_INTERVAL','30')); THRESH=int(os.getenv('FAIL_THRESHOLD','3'))
TIMEOUT=int(os.getenv('REQUEST_TIMEOUT','12')); BASE=int(os.getenv('BASE_PORT','21080'))
TEST_URLS=['https://www.google.com/generate_204','https://cp.cloudflare.com/generate_204']

def telegram(text):
    data=urllib.parse.urlencode({'chat_id':CHAT,'text':text}).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(f'https://api.telegram.org/bot{TOKEN}/sendMessage',data=data),timeout=10).read()
    except Exception as e:
        print('Telegram error:',e,flush=True)

def check(port):
    last='unknown error'
    for url in TEST_URLS:
        cmd=['curl','-fsS','--socks5-hostname',f'127.0.0.1:{port}','--connect-timeout','6','--max-time',str(TIMEOUT),'-o','/dev/null','-w','%{http_code} %{time_total}',url]
        p=subprocess.run(cmd,text=True,capture_output=True)
        if p.returncode==0:
            parts=p.stdout.strip().split()
            code=parts[0] if parts else '000'; sec=float(parts[1]) if len(parts)>1 else 0
            if code in ('200','204'):
                return True, round(sec*1000), f'HTTP {code}'
            last=f'HTTP {code}'
        else:
            last=(p.stderr.strip().splitlines()[-1] if p.stderr.strip() else f'curl exit {p.returncode}')[:180]
    return False,None,last

def load(i):
    p=STATE/f'{i}.json'
    if p.exists():
        try:return json.loads(p.read_text())
        except:pass
    return {'status':'unknown','fails':0,'down_since':None}

def save(i,s):
    (STATE/f'{i}.json').write_text(json.dumps(s),encoding='utf-8')

telegram(f'🟢 Xray monitor started\nMonitoring {len(NAMES)} server(s) every {INTERVAL}s')
while True:
    started=time.time()
    for i,name in enumerate(NAMES):
        s=load(i); ok,ms,detail=check(BASE+i)
        if ok:
            if s.get('status')=='down':
                ds=s.get('down_since') or time.time(); downtime=max(0,int(time.time()-ds))
                telegram(f'🟢 {name} RECOVERED\nVPN path is working again\nLatency: {ms} ms\nDowntime: {downtime//60}m {downtime%60}s')
            s={'status':'up','fails':0,'down_since':None,'last_ms':ms,'last_ok':int(time.time())}
        else:
            fails=int(s.get('fails',0))+1; s['fails']=fails; s['last_error']=detail
            if fails>=THRESH and s.get('status')!='down':
                s['status']='down'; s['down_since']=time.time()
                telegram(f'🔴 {name} DOWN\nEnd-to-end VLESS test failed {fails} times\nError: {detail}')
        save(i,s)
    elapsed=time.time()-started
    time.sleep(max(1,INTERVAL-elapsed))
PY
chmod 700 "$PY_FILE"

cat > "$CORE_SERVICE" <<EOFCORE
[Unit]
Description=Dedicated Xray Core for Telegram Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config $XRAY_CFG
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOFCORE

cat > "$SERVICE" <<'UNIT'
[Unit]
Description=Xray VLESS Telegram Monitor
After=network-online.target xray-monitor-core.service
Wants=network-online.target
Requires=xray-monitor-core.service

[Service]
Type=simple
EnvironmentFile=/opt/xray-telegram-monitor/monitor.env
ExecStart=/usr/bin/python3 /opt/xray-telegram-monitor/monitor.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/xray-telegram-monitor

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now xray-monitor-core.service
sleep 2
systemctl is-active --quiet xray-monitor-core.service || { journalctl -u xray-monitor-core -n 50 --no-pager; exit 1; }
systemctl enable --now xray-telegram-monitor.service
sleep 2
systemctl is-active --quiet xray-telegram-monitor.service || { journalctl -u xray-telegram-monitor -n 50 --no-pager; exit 1; }

echo
echo 'Installation complete.'
echo 'Monitor status: systemctl status xray-telegram-monitor --no-pager'
echo 'Live logs:      journalctl -u xray-telegram-monitor -f'
echo 'Xray logs:      journalctl -u xray-monitor-core -f'

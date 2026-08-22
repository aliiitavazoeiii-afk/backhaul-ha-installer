#!/usr/bin/env bash
set -Eeuo pipefail

PY=/opt/xray-telegram-monitor/monitor.py
ENV=/opt/xray-telegram-monitor/monitor.env

[[ $EUID -eq 0 ]] || { echo 'Run as root.'; exit 1; }
[[ -f "$PY" && -f "$ENV" ]] || { echo 'Xray Telegram Monitor is not installed.'; exit 1; }

cp -a "$PY" "${PY}.bak.$(date +%s)"

sed -i 's/^FAIL_THRESHOLD=.*/FAIL_THRESHOLD=1/' "$ENV"

python3 - "$PY" <<'PYCODE'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old="""            if fails>=THRESH and s.get('status')!='down':
                s['status']='down'; s['down_since']=time.time()
                telegram(f'🔴 {name} DOWN\\nEnd-to-end VLESS test failed {fails} times\\nError: {detail}')
"""
new="""            if fails>=THRESH:
                if s.get('status')!='down':
                    s['status']='down'; s['down_since']=time.time()
                ds=s.get('down_since') or time.time(); downtime=max(0,int(time.time()-ds))
                telegram(f'🔴 {name} STILL DOWN\\nDowntime: {downtime//60}m {downtime%60}s\\nFailed checks: {fails}\\nError: {detail}')
"""
if old not in s:
    raise SystemExit('Expected monitor code was not found; no changes made.')
p.write_text(s.replace(old,new),encoding='utf-8')
PYCODE

systemctl restart xray-telegram-monitor.service
sleep 2
systemctl is-active --quiet xray-telegram-monitor.service

echo 'Repeated DOWN alerts enabled every monitor cycle (30s by default).'
echo 'FAIL_THRESHOLD='$(grep '^FAIL_THRESHOLD=' "$ENV" | cut -d= -f2)

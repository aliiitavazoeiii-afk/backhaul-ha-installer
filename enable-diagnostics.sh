#!/usr/bin/env bash
set -Eeuo pipefail

RAW_BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/main"
ROLE="$(cat /etc/backhaul-ha/role 2>/dev/null || true)"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ "$ROLE" == "iran" || "$ROLE" == "foreign" ]] || { echo "Tunnel role not found. Install the tunnel first." >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y iperf3 iputils-ping iputils-tracepath curl python3 netcat-openbsd

curl -fsSL "$RAW_BASE/diagnose.sh" -o /usr/local/bin/tunnel-diagnose
chmod 0755 /usr/local/bin/tunnel-diagnose

if [[ "$ROLE" == "foreign" ]]; then
  cat > /etc/systemd/system/backhaul-diag-iperf.service <<'UNIT'
[Unit]
Description=Backhaul private diagnostic iperf3 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/iperf3 -s -B 127.0.0.1 -p 5201
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now backhaul-diag-iperf.service
  echo "Foreign diagnostics enabled: iperf3 is loopback-only on 127.0.0.1:5201."
else
  python3 - <<'PY'
from pathlib import Path
import re, shutil, time

def add_mapping(path, mapping):
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"Missing {path}")
    text = p.read_text()
    if mapping in text:
        print(f"Already present: {mapping}")
        return False
    m = re.search(r'(?ms)^ports\s*=\s*\[\n(?P<body>.*?)^\]', text)
    if not m:
        raise SystemExit(f"Cannot find ports array in {path}")
    body = m.group('body').rstrip()
    if body and not body.endswith(','):
        body += ','
    body += f'\n    "{mapping}"\n'
    new = text[:m.start('body')] + body + text[m.end('body'):]
    backup = f"{path}.diag-backup-{int(time.time())}"
    shutil.copy2(path, backup)
    p.write_text(new)
    print(f"Added {mapping}; backup: {backup}")
    return True

changed = False
changed |= add_mapping('/etc/backhaul/server-wss.toml', '10445=127.0.0.1:5201')
changed |= add_mapping('/etc/backhaul/server.toml', '11445=127.0.0.1:5201')
Path('/run/backhaul-diag-config-changed').write_text('1' if changed else '0')
PY
  if [[ "$(cat /run/backhaul-diag-config-changed 2>/dev/null || echo 0)" == "1" ]]; then
    systemctl restart backhaul backhaul-wss
    sleep 3
  fi
  rm -f /run/backhaul-diag-config-changed
  echo "Iran diagnostics enabled: WSS :10445 and TCP :11445 map privately to Foreign iperf3."
fi

echo
echo "Diagnostics installed/updated."
echo "Use tunnel-diagnose --help for the command reference."

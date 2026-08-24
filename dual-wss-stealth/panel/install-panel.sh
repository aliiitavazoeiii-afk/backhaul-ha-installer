#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root.' >&2; exit 1; }

PANEL_COMMIT='5a45133730ed8f5be861f907685eabcbbe5897a0'
REPO='aliiitavazoeiii-afk/backhaul-ha-installer'
RAW="https://raw.githubusercontent.com/${REPO}/${PANEL_COMMIT}/dual-wss-stealth/panel"
CFG=/etc/dual-stealth-panel
BIN=/usr/local/lib/dual-stealth-panel/panel.py
STATE=$CFG/state.json
TOKEN=$CFG/token

for x in python3 curl systemctl; do command -v "$x" >/dev/null || { echo "[x] Missing $x" >&2; exit 2; }; done
for f in /usr/local/bin/stealthctl /root/dual-stealth-a.env /root/dual-stealth-b.env /etc/dual-wss-stealth/a-server.toml /etc/dual-wss-stealth/b-server.toml; do
  [[ -e "$f" ]] || { echo "[x] Current Dual WSS Stealth installation not found: $f" >&2; exit 3; }
done

install -d -m 0700 "$CFG"
install -d -m 0755 /usr/local/lib/dual-stealth-panel

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
curl -fL --retry 4 --retry-delay 2 "$RAW/panel.py" -o "$tmp"
python3 -m py_compile "$tmp"
install -m 0755 "$tmp" "$BIN"

if [[ ! -s "$TOKEN" ]]; then
  python3 - <<'PY' > "$TOKEN"
import secrets
print(secrets.token_urlsafe(32))
PY
  chmod 0600 "$TOKEN"
fi

A=''; B=''
if [[ -s "$STATE" ]]; then
  A=$(python3 -c 'import json;print(json.load(open("/etc/dual-stealth-panel/state.json")).get("foreign_a_ip",""))' 2>/dev/null || true)
  B=$(python3 -c 'import json;print(json.load(open("/etc/dual-stealth-panel/state.json")).get("foreign_b_ip",""))' 2>/dev/null || true)
fi
read -r -p "Foreign A management IPv4 [${A:-193.57.9.55}]: " x; A="${x:-${A:-193.57.9.55}}"
read -r -p "Foreign B management IPv4 [${B:-193.57.9.184}]: " x; B="${x:-${B:-193.57.9.184}}"
python3 - "$A" "$B" <<'PY'
import ipaddress,json,os,sys
A=str(ipaddress.ip_address(sys.argv[1])); B=str(ipaddress.ip_address(sys.argv[2]))
if ':' in A or ':' in B: raise SystemExit('IPv4 required')
p='/etc/dual-stealth-panel/state.json'
with open(p,'w') as f: json.dump({'version':'0.2.0','foreign_a_ip':A,'foreign_b_ip':B},f,indent=2);f.write('\n')
os.chmod(p,0o600)
PY

cat > /etc/systemd/system/dual-stealth-panel.service <<EOFUNIT
[Unit]
Description=Dual WSS Stealth local management panel
After=network-online.target haproxy.service nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $BIN
Environment=AEGIS_PANEL_BIND=127.0.0.1
Environment=AEGIS_PANEL_PORT=8787
Restart=always
RestartSec=2
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=read-only
ProtectSystem=full
ReadWritePaths=/etc/dual-stealth-panel /etc/dual-wss-stealth /etc/nginx/sites-available /etc/haproxy /root /run /var/run

[Install]
WantedBy=multi-user.target
EOFUNIT

cat > /usr/local/bin/aegis-panelctl <<'EOFCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-status}" in
 status) systemctl status dual-stealth-panel --no-pager || true ;;
 token) cat /etc/dual-stealth-panel/token ; echo ;;
 url) echo 'http://127.0.0.1:8787/' ;;
 logs) journalctl -u dual-stealth-panel -n "${2:-100}" --no-pager ;;
 restart) systemctl restart dual-stealth-panel ;;
 *) echo 'Usage: aegis-panelctl {status|token|url|logs|restart}' >&2; exit 2;;
esac
EOFCTL
chmod 0755 /usr/local/bin/aegis-panelctl

systemctl daemon-reload
systemctl enable --now dual-stealth-panel >/dev/null
sleep 1
systemctl is-active --quiet dual-stealth-panel || { journalctl -u dual-stealth-panel -n 50 --no-pager; exit 4; }

echo '[+] Aegis Control installed (loopback only).'
echo '[+] Open it safely from your PC with:'
echo '    ssh -L 8787:127.0.0.1:8787 root@5.10.248.50'
echo '    then browse: http://127.0.0.1:8787/'
echo '[+] Panel token (store it securely):'
cat "$TOKEN"; echo

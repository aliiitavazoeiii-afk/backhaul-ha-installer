#!/usr/bin/env bash
set -u
SERVICE_NAME="xhttp-reality-server"
PORT="${PORT:-443}"
[[ -f /root/xhttp-reality-client.env ]] && source /root/xhttp-reality-client.env

echo "=== SERVICE ==="
systemctl --no-pager --full status "${SERVICE_NAME}.service" | sed -n '1,18p' || true
echo
echo "=== LISTENER ==="
ss -lntp "( sport = :${PORT} )" || true
echo
echo "=== CONFIG TEST ==="
/usr/local/lib/xhttp-reality/xray run -test -c /etc/xhttp-reality/server.json || true
echo
echo "=== CONNECTIONS ==="
ss -tnp | grep '/xray' || true
echo
echo "=== RESOURCE USE ==="
ps -C xray -o pid,%cpu,%mem,rss,vsz,etime,cmd 2>/dev/null || \
  ps aux | grep '/usr/local/lib/xhttp-reality/xray' | grep -v grep || true
echo
echo "=== LAST LOGS ==="
journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager || true

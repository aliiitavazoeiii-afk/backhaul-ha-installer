#!/usr/bin/env bash
set -u
SOCKS_PORT="${SOCKS_PORT:-10818}"
SERVICE_NAME="xhttp-reality-client"

echo "=== SERVICE ==="
systemctl --no-pager --full status "${SERVICE_NAME}.service" | sed -n '1,18p' || true
echo
echo "=== LISTENER ==="
ss -lntp "( sport = :${SOCKS_PORT} )" || true
echo
echo "=== CONFIG TEST ==="
/usr/local/lib/xhttp-reality/xray run -test -c /etc/xhttp-reality/client.json || true
echo
echo "=== END-TO-END ==="
curl -v --max-time 15 --connect-timeout 6 \
  --socks5-hostname "127.0.0.1:${SOCKS_PORT}" https://icanhazip.com || true
echo
echo "=== RESOURCE USE ==="
ps -C xray -o pid,%cpu,%mem,rss,vsz,etime,cmd 2>/dev/null || \
  ps aux | grep '/usr/local/lib/xhttp-reality/xray' | grep -v grep || true
echo
echo "=== LAST LOGS ==="
journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager || true

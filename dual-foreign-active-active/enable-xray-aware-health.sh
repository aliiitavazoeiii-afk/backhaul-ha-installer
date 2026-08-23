#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root' >&2; exit 1; }
ROLE="$(cat /etc/dual-backhaul-ha/role 2>/dev/null || true)"
[[ "$ROLE" == "foreign-a" || "$ROLE" == "foreign-b" ]] || { echo '[x] Run this only on a Foreign node' >&2; exit 2; }

install -d -m 0755 /opt/dual-backhaul-health
cat > /opt/dual-backhaul-health/server.py <<'PY'
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

XRAY_HOST = '127.0.0.1'
XRAY_PORT = 443


def xray_up():
    try:
        with socket.create_connection((XRAY_HOST, XRAY_PORT), timeout=0.5):
            return True
    except OSError:
        return False


class Server(ThreadingHTTPServer):
    request_queue_size = 128
    daemon_threads = True


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/healthz':
            self.send_response(404)
            self.end_headers()
            return

        ok = xray_up()
        body = b'XRAY_OK\n' if ok else b'XRAY_DOWN\n'
        self.send_response(200 if ok else 503)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


Server(('127.0.0.1', 18090), H).serve_forever()
PY

systemctl restart dual-bh-health
sleep 1

code="$(curl -sS -o /tmp/dual-health-body.$$ -w '%{http_code}' --max-time 2 http://127.0.0.1:18090/healthz || true)"
body="$(cat /tmp/dual-health-body.$$ 2>/dev/null || true)"
rm -f /tmp/dual-health-body.$$

echo "[i] Local health: HTTP=${code:-000} ${body}"
if [[ "$code" == "200" ]]; then
  echo '[+] Xray-aware Foreign health enabled.'
else
  echo '[!] Health service is active but Xray 127.0.0.1:443 is not accepting TCP connections.' >&2
fi

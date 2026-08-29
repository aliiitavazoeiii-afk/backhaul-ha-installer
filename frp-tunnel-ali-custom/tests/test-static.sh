#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/install.sh"
bash -n "$ROOT/frp-tunnel"
bash -n "$ROOT/bootstrap.sh"
bash -n "$ROOT/hotfix-wss-edge.sh"

grep -q 'transport.tcpMux = false' "$ROOT/install.sh"
grep -q 'transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"' "$ROOT/install.sh"
grep -q 'transport.tls.certFile = ' "$ROOT/install.sh"
grep -q 'auth.additionalScopes = \["HeartBeats", "NewWorkConns"\]' "$ROOT/install.sh"
grep -q 'auth.tokenSource.type = "file"' "$ROOT/install.sh"
if grep -q 'auth.token = ' "$ROOT/install.sh"; then echo "inline token found" >&2; exit 1; fi
if grep -q 'install .*"/usr/local/bin/frps"' "$ROOT/install.sh"; then echo "generic frps path found" >&2; exit 1; fi
if grep -q 'install .*"/usr/local/bin/frpc"' "$ROOT/install.sh"; then echo "generic frpc path found" >&2; exit 1; fi

grep -q 'proxy_pass http://127.0.0.1:' "$ROOT/hotfix-wss-edge.sh"
grep -q 'location = /~!frp' "$ROOT/hotfix-wss-edge.sh"
grep -q 'ssl_protocols TLSv1.2 TLSv1.3' "$ROOT/hotfix-wss-edge.sh"
grep -q '^RUNTIME_PIN=' "$ROOT/bootstrap.sh"
grep -q '^HOTFIX_PIN=' "$ROOT/bootstrap.sh"

grep -q 'End-to-end TCP path' "$ROOT/frp-tunnel"
grep -q 'STATUS: 🟢 READY FOR TRAFFIC' "$ROOT/frp-tunnel"

echo "static checks: OK"

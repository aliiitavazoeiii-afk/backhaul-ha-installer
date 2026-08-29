#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/install.sh"
bash -n "$ROOT/frp-tunnel"
bash -n "$ROOT/bootstrap.sh"

grep -q 'transport.tcpMux = false' "$ROOT/install.sh"
grep -q 'transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"' "$ROOT/install.sh"
grep -q 'transport.tls.certFile = ' "$ROOT/install.sh"
grep -q 'auth.additionalScopes = \["HeartBeats", "NewWorkConns"\]' "$ROOT/install.sh"
grep -q 'auth.tokenSource.type = "file"' "$ROOT/install.sh"
! grep -q 'auth.token = ' "$ROOT/install.sh"
! grep -q 'install .*"/usr/local/bin/frps"' "$ROOT/install.sh"
! grep -q 'install .*"/usr/local/bin/frpc"' "$ROOT/install.sh"
grep -q 'End-to-end TCP path' "$ROOT/frp-tunnel"
grep -q 'STATUS: 🟢 READY FOR TRAFFIC' "$ROOT/frp-tunnel"

echo "static checks: OK"

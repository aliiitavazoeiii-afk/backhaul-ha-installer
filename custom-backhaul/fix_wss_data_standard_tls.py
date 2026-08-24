#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
p = root / "internal/utils/network/ws_dialer.go"
s = p.read_text()

# The base custom-v2 patch deliberately removes crypto/tls because WSS uses uTLS.
# For this diagnostic build only, keep uTLS for the control channel but use the
# standard Go TLS client for data tunnel connections (appendID=true). This
# isolates uTLS as the only changed variable while preserving SNI, certificate
# verification and HTTP/1.1 ALPN.
if '"crypto/tls"' not in s:
    anchor = 'import (\n\t"context"\n'
    if anchor not in s:
        raise SystemExit("import anchor not found")
    s = s.replace(anchor, 'import (\n\t"context"\n\t"crypto/tls"\n', 1)

anchor = '''\t\t\t\trawConn, err := TcpDialer(dialCtx, edgeIP, "", timeout, keepalive, nodelay, 1, SO_RCVBUF, SO_SNDBUF, 0)\n\t\t\t\tif err != nil {\n\t\t\t\t\treturn nil, err\n\t\t\t\t}\n\t\t\t\tuconn := utls.UClient(rawConn, &utls.Config{\n'''
replacement = '''\t\t\t\trawConn, err := TcpDialer(dialCtx, edgeIP, "", timeout, keepalive, nodelay, 1, SO_RCVBUF, SO_SNDBUF, 0)\n\t\t\t\tif err != nil {\n\t\t\t\t\treturn nil, err\n\t\t\t\t}\n\n\t\t\t\tif appendID {\n\t\t\t\t\ttlsConn := tls.Client(rawConn, &tls.Config{\n\t\t\t\t\t\tServerName:         serverName,\n\t\t\t\t\t\tInsecureSkipVerify: tlsSkipVerify,\n\t\t\t\t\t\tNextProtos:         []string{"http/1.1"},\n\t\t\t\t\t})\n\t\t\t\t\tif err := tlsConn.HandshakeContext(dialCtx); err != nil {\n\t\t\t\t\t\t_ = rawConn.Close()\n\t\t\t\t\t\treturn nil, err\n\t\t\t\t\t}\n\t\t\t\t\treturn tlsConn, nil\n\t\t\t\t}\n\n\t\t\t\tuconn := utls.UClient(rawConn, &utls.Config{\n'''

if anchor not in s:
    raise SystemExit("custom WSS TLS dialer anchor not found")
s = s.replace(anchor, replacement, 1)

required = [
    'if appendID {',
    'tlsConn := tls.Client(rawConn, &tls.Config{',
    'HandshakeContext(dialCtx)',
    'NextProtos:         []string{"http/1.1"}',
    'uconn := utls.UClient',
]
for marker in required:
    if marker not in s:
        raise SystemExit(f"diagnostic marker missing: {marker}")

p.write_text(s)
print("diagnostic: WSSMux data tunnels use standard Go TLS; control keeps uTLS")

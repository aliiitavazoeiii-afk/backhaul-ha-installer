#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
p = root / "internal/utils/network/ws_dialer.go"
s = p.read_text()

old = '''\t\t\tuconn := utls.UClient(rawConn, &utls.Config{\n\t\t\t\tServerName:         serverName,\n\t\t\t\tInsecureSkipVerify: tlsSkipVerify,\n\t\t\t}, utls.HelloChrome_Auto)\n\t\t\tif err := uconn.Handshake(); err != nil {\n\t\t\t\t_ = rawConn.Close()\n\t\t\t\treturn nil, err\n\t\t\t}\n'''

new = '''\t\t\tuconn := utls.UClient(rawConn, &utls.Config{\n\t\t\t\tServerName:         serverName,\n\t\t\t\tInsecureSkipVerify: tlsSkipVerify,\n\t\t\t\tNextProtos:         []string{"http/1.1"},\n\t\t\t}, utls.HelloChrome_Auto)\n\n\t\t\t// Gorilla WebSocket performs an HTTP/1.1 Upgrade handshake. Browser-parrot\n\t\t\t// ClientHello presets advertise h2 by default, which can make Go's HTTPS\n\t\t\t// server negotiate HTTP/2 and then reject the following HTTP/1.1 GET as a\n\t\t\t// bogus HTTP/2 preface. Keep the Chrome-like TLS shape while constraining\n\t\t\t// ALPN to the application protocol this transport actually implements.\n\t\t\tif err := uconn.BuildHandshakeState(); err != nil {\n\t\t\t\t_ = rawConn.Close()\n\t\t\t\treturn nil, err\n\t\t\t}\n\t\t\talpnFound := false\n\t\t\tfor _, extension := range uconn.Extensions {\n\t\t\t\tif alpn, ok := extension.(*utls.ALPNExtension); ok {\n\t\t\t\t\talpn.AlpnProtocols = []string{"http/1.1"}\n\t\t\t\t\talpnFound = true\n\t\t\t\t\tbreak\n\t\t\t\t}\n\t\t\t}\n\t\t\tif !alpnFound {\n\t\t\t\t_ = rawConn.Close()\n\t\t\t\treturn nil, fmt.Errorf("uTLS Chrome preset missing ALPN extension")\n\t\t\t}\n\t\t\tif err := uconn.Handshake(); err != nil {\n\t\t\t\t_ = rawConn.Close()\n\t\t\t\treturn nil, err\n\t\t\t}\n'''

if old not in s:
    raise SystemExit("custom WSS uTLS handshake anchor not found")

s = s.replace(old, new, 1)

# Safety assertions: h2 must not be explicitly offered by this custom WSS dialer.
if 'NextProtos:         []string{"http/1.1"}' not in s:
    raise SystemExit("HTTP/1.1 NextProtos constraint missing")
if 'alpn.AlpnProtocols = []string{"http/1.1"}' not in s:
    raise SystemExit("explicit ALPN rewrite missing")

p.write_text(s)
print("forced HTTP/1.1 ALPN for custom WSS WebSocket dialer")

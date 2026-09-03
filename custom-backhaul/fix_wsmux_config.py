#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
p = root / "internal/server/server.go"
s = p.read_text()

# The initial patch used a generic ProxyProtocol anchor which also exists in
# TcpMuxConfig. Remove the misplaced fields there if present.
bad = '''\t\t\tProxyProtocol:    s.config.ProxyProtocol,\n\t\t\tControlPath:      s.config.WSControlPath,\n\t\t\tTunnelPath:       s.config.WSTunnelPath,\n\t\t}\n'''
good = '''\t\t\tProxyProtocol:    s.config.ProxyProtocol,\n\t\t}\n'''
if bad in s:
    s = s.replace(bad, good, 1)

# Add the fields only inside the WSMux config literal.
marker = 'wsMuxConfig := &transport.WsMuxConfig{'
start = s.find(marker)
if start < 0:
    raise SystemExit("WsMuxConfig block not found")
end = s.find('\n\t\t}', start)
if end < 0:
    raise SystemExit("WsMuxConfig block end not found")
block = s[start:end]
needle = '\t\t\tProxyProtocol:    s.config.ProxyProtocol,'
if needle not in block:
    raise SystemExit("WsMuxConfig ProxyProtocol anchor not found")
if 'ControlPath:' not in block:
    block = block.replace(
        needle,
        needle + '\n\t\t\tControlPath:      s.config.WSControlPath,\n\t\t\tTunnelPath:       s.config.WSTunnelPath,',
        1,
    )
    s = s[:start] + block + s[end:]

# Safety assertions: custom path fields must exist in WSMux but not TcpMux.
tcp_start = s.find('tcpMuxConfig := &transport.TcpMuxConfig{')
tcp_end = s.find('\n\t\t}', tcp_start)
tcp_block = s[tcp_start:tcp_end]
if 'ControlPath:' in tcp_block or 'TunnelPath:' in tcp_block:
    raise SystemExit("custom WS path fields still leaked into TcpMuxConfig")

ws_start = s.find(marker)
ws_end = s.find('\n\t\t}', ws_start)
ws_block = s[ws_start:ws_end]
if 'ControlPath:' not in ws_block or 'TunnelPath:' not in ws_block:
    raise SystemExit("custom WS path fields missing from WsMuxConfig")

p.write_text(s)
print("corrected WSMux server config targeting")

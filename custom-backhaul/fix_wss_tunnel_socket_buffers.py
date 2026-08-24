#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
p = root / "internal/client/transport/wsmux.go"
s = p.read_text()

old = 'network.WebSocketDialerCustom(c.ctx, c.config.RemoteAddr, c.config.EdgeIP, normalizeClientWSPath(c.config.TunnelPath, "/tunnel"), true, c.config.DialTimeOut, c.config.KeepAlive, c.config.Nodelay, c.config.Token, c.config.Mode, 3, 2*1024*1024, 2*1024*1024, c.config.TLSSkipVerify, c.config.TLSServerName, c.config.WSUserAgent, c.config.WSOrigin)'
new = 'network.WebSocketDialerCustom(c.ctx, c.config.RemoteAddr, c.config.EdgeIP, normalizeClientWSPath(c.config.TunnelPath, "/tunnel"), true, c.config.DialTimeOut, c.config.KeepAlive, c.config.Nodelay, c.config.Token, c.config.Mode, 3, 0, 0, c.config.TLSSkipVerify, c.config.TLSServerName, c.config.WSUserAgent, c.config.WSOrigin)'

if old not in s:
    raise SystemExit("WSMux tunnel socket-buffer anchor not found")

s = s.replace(old, new, 1)

if 'c.config.Mode, 3, 0, 0, c.config.TLSSkipVerify' not in s:
    raise SystemExit("WSMux tunnel socket-buffer override was not removed")

p.write_text(s)
print("restored OS-default socket buffers for WSSMux data tunnels")

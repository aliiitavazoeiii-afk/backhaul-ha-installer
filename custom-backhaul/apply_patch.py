#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()


def edit(rel, old, new, count=1):
    p = root / rel
    s = p.read_text()
    actual = s.count(old)
    if actual < count:
        raise SystemExit(f"patch anchor missing in {rel}: expected >= {count}, got {actual}\nANCHOR:\n{old[:300]}")
    s = s.replace(old, new, count)
    p.write_text(s)
    print(f"patched {rel}")


# 1) Public configuration knobs. Defaults preserve upstream paths; TLS verification
# is secure-by-default because tls_skip_verify defaults to false.
edit(
    "config/config.go",
    '\tProxyProtocol    bool          `toml:"proxy_protocol"`\n}',
    '\tProxyProtocol    bool          `toml:"proxy_protocol"`\n\tWSControlPath   string        `toml:"ws_control_path"`\n\tWSTunnelPath    string        `toml:"ws_tunnel_path"`\n}',
)
edit(
    "config/config.go",
    '\tSO_SNDBUF        int           `toml:"so_sndbuf"`\n}',
    '\tSO_SNDBUF        int           `toml:"so_sndbuf"`\n\tWSControlPath   string        `toml:"ws_control_path"`\n\tWSTunnelPath    string        `toml:"ws_tunnel_path"`\n\tTLSSkipVerify   bool          `toml:"tls_skip_verify"`\n\tTLSServerName   string        `toml:"tls_server_name"`\n\tWSUserAgent     string        `toml:"ws_user_agent"`\n\tWSOrigin        string        `toml:"ws_origin"`\n}',
)

# 2) Thread custom fields into WSMux server/client configs.
edit(
    "internal/server/server.go",
    '\t\t\tProxyProtocol:    s.config.ProxyProtocol,\n\t\t}',
    '\t\t\tProxyProtocol:    s.config.ProxyProtocol,\n\t\t\tControlPath:      s.config.WSControlPath,\n\t\t\tTunnelPath:       s.config.WSTunnelPath,\n\t\t}',
)
edit(
    "internal/client/client.go",
    '\t\t\tAggressivePool:   c.config.AggressivePool,\n\t\t\tEdgeIP:           c.config.EdgeIP,\n\t\t}',
    '\t\t\tAggressivePool:   c.config.AggressivePool,\n\t\t\tEdgeIP:           c.config.EdgeIP,\n\t\t\tControlPath:      c.config.WSControlPath,\n\t\t\tTunnelPath:       c.config.WSTunnelPath,\n\t\t\tTLSSkipVerify:    c.config.TLSSkipVerify,\n\t\t\tTLSServerName:    c.config.TLSServerName,\n\t\t\tWSUserAgent:      c.config.WSUserAgent,\n\t\t\tWSOrigin:         c.config.WSOrigin,\n\t\t}',
)

# 3) WSMux server: custom secret paths, generic 404 for probes, jittered heartbeat,
# and variable-size control frames. Signal byte remains byte 0 for compatibility.
edit(
    "internal/server/transport/wsmux.go",
    '"net/http"\n\t"runtime"',
    '"net/http"\n\t"math/rand"\n\t"runtime"',
)
edit(
    "internal/server/transport/wsmux.go",
    '\tProxyProtocol    bool\n}',
    '\tProxyProtocol    bool\n\tControlPath      string\n\tTunnelPath       string\n}',
)
server_helpers = r'''
func normalizeWSPath(value, fallback string) string {
	if value == "" {
		return fallback
	}
	if !strings.HasPrefix(value, "/") {
		return "/" + value
	}
	return value
}

func paddedControlFrame(signal byte) []byte {
	n := 8 + rand.Intn(57)
	buf := make([]byte, n)
	buf[0] = signal
	for i := 1; i < len(buf); i++ {
		buf[i] = byte(rand.Intn(256))
	}
	return buf
}

func jitterHeartbeat(base time.Duration) time.Duration {
	if base <= 0 {
		base = 40 * time.Second
	}
	delta := int64(base) / 5
	if delta < 1 {
		return base
	}
	return base + time.Duration(rand.Int63n(delta*2+1)-delta)
}
'''
edit(
    "internal/server/transport/wsmux.go",
    '\treturn server\n}\n\nfunc (s *WsMuxTransport) Start()',
    '\treturn server\n}\n' + server_helpers + '\nfunc (s *WsMuxTransport) Start()',
)
edit(
    "internal/server/transport/wsmux.go",
    '\tticker := time.NewTicker(s.config.Heartbeat)\n\tdefer ticker.Stop()',
    '\theartbeatTimer := time.NewTimer(jitterHeartbeat(s.config.Heartbeat))\n\tdefer heartbeatTimer.Stop()',
)
edit(
    "internal/server/transport/wsmux.go",
    'case <-ticker.C:\n\t\t\terr := s.controlChannel.WriteMessage(websocket.BinaryMessage, []byte{utils.SG_HB})',
    'case <-heartbeatTimer.C:\n\t\t\terr := s.controlChannel.WriteMessage(websocket.BinaryMessage, paddedControlFrame(utils.SG_HB))',
)
edit(
    "internal/server/transport/wsmux.go",
    '\t\t\ts.logger.Debug("heartbeat signal sent successfully")',
    '\t\t\ts.logger.Debug("heartbeat signal sent successfully")\n\t\t\theartbeatTimer.Reset(jitterHeartbeat(s.config.Heartbeat))',
)
for sig in ("SG_Closed", "SG_Chan"):
    edit(
        "internal/server/transport/wsmux.go",
        f'[]byte{{utils.{sig}}}',
        f'paddedControlFrame(utils.{sig})',
    )
edit(
    "internal/server/transport/wsmux.go",
    '\taddr := s.config.BindAddr\n\tupgrader := websocket.Upgrader{',
    '\taddr := s.config.BindAddr\n\tcontrolPath := normalizeWSPath(s.config.ControlPath, "/channel")\n\ttunnelPath := normalizeWSPath(s.config.TunnelPath, "/tunnel")\n\tupgrader := websocket.Upgrader{',
)
edit(
    "internal/server/transport/wsmux.go",
    '''\t\t\t// Read the "Authorization" header\n\t\t\tauthHeader := r.Header.Get("Authorization")\n\t\t\tif authHeader != fmt.Sprintf("Bearer %v", s.config.Token) {\n\t\t\t\ts.logger.Warnf("unauthorized request from %s, closing connection", r.RemoteAddr)\n\t\t\t\thttp.Error(w, "unauthorized", http.StatusUnauthorized) // Send 401 Unauthorized response\n\t\t\t\treturn\n\t\t\t}\n''',
    '''\t\t\tisControl := r.URL.Path == controlPath\n\t\t\tisTunnel := r.URL.Path == tunnelPath || strings.HasPrefix(r.URL.Path, tunnelPath+"/")\n\t\t\tif !isControl && !isTunnel {\n\t\t\t\thttp.NotFound(w, r)\n\t\t\t\treturn\n\t\t\t}\n\n\t\t\tauthHeader := r.Header.Get("Authorization")\n\t\t\tif authHeader != fmt.Sprintf("Bearer %v", s.config.Token) {\n\t\t\t\t// Avoid exposing a distinct authentication oracle to active probes.\n\t\t\t\thttp.NotFound(w, r)\n\t\t\t\treturn\n\t\t\t}\n''',
)
edit(
    "internal/server/transport/wsmux.go",
    'if r.URL.Path == "/channel" {',
    'if isControl {',
)
edit(
    "internal/server/transport/wsmux.go",
    '} else if strings.HasPrefix(r.URL.Path, "/tunnel") {',
    '} else if isTunnel {',
)

# 4) WSMux client: use secret paths and custom WSS dialer; pad replies/close frames.
edit(
    "internal/client/transport/wsmux.go",
    '"fmt"\n\t"strings"',
    '"fmt"\n\t"math/rand"\n\t"strings"',
)
edit(
    "internal/client/transport/wsmux.go",
    '\tEdgeIP           string\n}',
    '\tEdgeIP           string\n\tControlPath      string\n\tTunnelPath       string\n\tTLSSkipVerify    bool\n\tTLSServerName    string\n\tWSUserAgent      string\n\tWSOrigin         string\n}',
)
client_helpers = r'''
func normalizeClientWSPath(value, fallback string) string {
	if value == "" {
		return fallback
	}
	if !strings.HasPrefix(value, "/") {
		return "/" + value
	}
	return value
}

func paddedClientControlFrame(signal byte) []byte {
	n := 8 + rand.Intn(57)
	buf := make([]byte, n)
	buf[0] = signal
	for i := 1; i < len(buf); i++ {
		buf[i] = byte(rand.Intn(256))
	}
	return buf
}
'''
edit(
    "internal/client/transport/wsmux.go",
    '\treturn client\n}\n\nfunc (c *WsMuxTransport) Start()',
    '\treturn client\n}\n' + client_helpers + '\nfunc (c *WsMuxTransport) Start()',
)
edit(
    "internal/client/transport/wsmux.go",
    'network.WebSocketDialer(c.ctx, c.config.RemoteAddr, c.config.EdgeIP, "/channel", c.config.DialTimeOut, c.config.KeepAlive, true, c.config.Token, c.config.Mode, 3, 0, 0)',
    'network.WebSocketDialerCustom(c.ctx, c.config.RemoteAddr, c.config.EdgeIP, normalizeClientWSPath(c.config.ControlPath, "/channel"), false, c.config.DialTimeOut, c.config.KeepAlive, true, c.config.Token, c.config.Mode, 3, 0, 0, c.config.TLSSkipVerify, c.config.TLSServerName, c.config.WSUserAgent, c.config.WSOrigin)',
)
edit(
    "internal/client/transport/wsmux.go",
    'network.WebSocketDialer(c.ctx, c.config.RemoteAddr, c.config.EdgeIP, "/tunnel", c.config.DialTimeOut, c.config.KeepAlive, c.config.Nodelay, c.config.Token, c.config.Mode, 3, 2*1024*1024, 2*1024*1024)',
    'network.WebSocketDialerCustom(c.ctx, c.config.RemoteAddr, c.config.EdgeIP, normalizeClientWSPath(c.config.TunnelPath, "/tunnel"), true, c.config.DialTimeOut, c.config.KeepAlive, c.config.Nodelay, c.config.Token, c.config.Mode, 3, 2*1024*1024, 2*1024*1024, c.config.TLSSkipVerify, c.config.TLSServerName, c.config.WSUserAgent, c.config.WSOrigin)',
)
for sig in ("SG_Closed", "SG_HB"):
    edit(
        "internal/client/transport/wsmux.go",
        f'[]byte{{utils.{sig}}}',
        f'paddedClientControlFrame(utils.{sig})',
    )

# 5) Add a WSMux-only custom dialer while preserving the upstream function signature
# for ordinary WS/WSS transport users.
edit(
    "internal/utils/network/ws_dialer.go",
    '\t"crypto/tls"\n',
    '',
)
edit(
    "internal/utils/network/ws_dialer.go",
    '\t"github.com/gorilla/websocket"\n\t"github.com/musix/backhaul/config"',
    '\t"github.com/gorilla/websocket"\n\t"github.com/musix/backhaul/config"\n\tutls "github.com/refraction-networking/utls"',
)
old_wrapper = '''func WebSocketDialer(ctx context.Context, addr string, edgeIP string, path string, timeout time.Duration, keepalive time.Duration, nodelay bool, token string, mode config.TransportType, retry int, SO_RCVBUF int, SO_SNDBUF int) (*websocket.Conn, error) {\n\tvar tunnelWSConn *websocket.Conn\n\tvar err error\n'''
new_wrapper = '''func WebSocketDialer(ctx context.Context, addr string, edgeIP string, path string, timeout time.Duration, keepalive time.Duration, nodelay bool, token string, mode config.TransportType, retry int, SO_RCVBUF int, SO_SNDBUF int) (*websocket.Conn, error) {\n\treturn WebSocketDialerCustom(ctx, addr, edgeIP, path, path != "/channel", timeout, keepalive, nodelay, token, mode, retry, SO_RCVBUF, SO_SNDBUF, true, "", "", "")\n}\n\nfunc WebSocketDialerCustom(ctx context.Context, addr string, edgeIP string, path string, appendID bool, timeout time.Duration, keepalive time.Duration, nodelay bool, token string, mode config.TransportType, retry int, SO_RCVBUF int, SO_SNDBUF int, tlsSkipVerify bool, tlsServerName string, wsUserAgent string, wsOrigin string) (*websocket.Conn, error) {\n\tvar tunnelWSConn *websocket.Conn\n\tvar err error\n'''
edit("internal/utils/network/ws_dialer.go", old_wrapper, new_wrapper)
edit(
    "internal/utils/network/ws_dialer.go",
    'attemptDialWebSocket(ctx, addr, edgeIP, path, timeout, keepalive, nodelay, token, mode, SO_RCVBUF, SO_SNDBUF)',
    'attemptDialWebSocketCustom(ctx, addr, edgeIP, path, appendID, timeout, keepalive, nodelay, token, mode, SO_RCVBUF, SO_SNDBUF, tlsSkipVerify, tlsServerName, wsUserAgent, wsOrigin)',
)
edit(
    "internal/utils/network/ws_dialer.go",
    'func attemptDialWebSocket(ctx context.Context, addr string, edgeIP string, path string, timeout time.Duration, keepalive time.Duration, nodelay bool, token string, mode config.TransportType, SO_RCVBUF int, SO_SNDBUF int) (*websocket.Conn, error) {',
    'func attemptDialWebSocketCustom(ctx context.Context, addr string, edgeIP string, path string, appendID bool, timeout time.Duration, keepalive time.Duration, nodelay bool, token string, mode config.TransportType, SO_RCVBUF int, SO_SNDBUF int, tlsSkipVerify bool, tlsServerName string, wsUserAgent string, wsOrigin string) (*websocket.Conn, error) {',
)
edit(
    "internal/utils/network/ws_dialer.go",
    '\trandomUserAgent := userAgents[rand.Intn(len(userAgents))]\n',
    '\trandomUserAgent := userAgents[rand.Intn(len(userAgents))]\n\tif wsUserAgent != "" {\n\t\trandomUserAgent = wsUserAgent\n\t}\n',
)
edit(
    "internal/utils/network/ws_dialer.go",
    '\theaders.Add("User-Agent", randomUserAgent)\n',
    '\theaders.Add("User-Agent", randomUserAgent)\n\tif wsOrigin != "" {\n\t\theaders.Add("Origin", wsOrigin)\n\t}\n',
)
edit(
    "internal/utils/network/ws_dialer.go",
    '\tif path != "/channel" {\n',
    '\tif appendID {\n',
)
old_wss = '''\tcase config.WSS, config.WSSMUX:\n\t\twsURL = fmt.Sprintf("wss://%s%s", addr, path)\n\n\t\t// Create a TLS configuration that allows insecure connections\n\t\ttlsConfig := &tls.Config{\n\t\t\tInsecureSkipVerify: true, // Skip server certificate verification\n\t\t}\n\n\t\tdialer = websocket.Dialer{\n\t\t\tEnableCompression: true,\n\t\t\tTLSClientConfig:   tlsConfig,        // Pass the insecure TLS config here\n\t\t\tHandshakeTimeout:  45 * time.Second, // default handshake timeout\n\t\t\tNetDial: func(_, addr string) (net.Conn, error) {\n\t\t\t\tconn, err := TcpDialer(ctx, edgeIP, "", timeout, keepalive, nodelay, 1, SO_RCVBUF, SO_SNDBUF, 0)\n\t\t\t\tif err != nil {\n\t\t\t\t\treturn nil, err\n\t\t\t\t}\n\t\t\t\treturn conn, nil\n\t\t\t},\n\t\t}\n'''
new_wss = '''\tcase config.WSS, config.WSSMUX:\n\t\twsURL = fmt.Sprintf("wss://%s%s", addr, path)\n\n\t\tserverName := tlsServerName\n\t\tif serverName == "" {\n\t\t\thost, _, splitErr := net.SplitHostPort(addr)\n\t\t\tif splitErr == nil {\n\t\t\t\tserverName = host\n\t\t\t} else {\n\t\t\t\tserverName = addr\n\t\t\t}\n\t\t}\n\n\t\tdialer = websocket.Dialer{\n\t\t\tEnableCompression: true,\n\t\t\tHandshakeTimeout:  45 * time.Second,\n\t\t\tNetDialTLSContext: func(dialCtx context.Context, _, _ string) (net.Conn, error) {\n\t\t\t\trawConn, err := TcpDialer(dialCtx, edgeIP, "", timeout, keepalive, nodelay, 1, SO_RCVBUF, SO_SNDBUF, 0)\n\t\t\t\tif err != nil {\n\t\t\t\t\treturn nil, err\n\t\t\t\t}\n\t\t\t\tuconn := utls.UClient(rawConn, &utls.Config{\n\t\t\t\t\tServerName:         serverName,\n\t\t\t\t\tInsecureSkipVerify: tlsSkipVerify,\n\t\t\t\t}, utls.HelloChrome_Auto)\n\t\t\t\tif err := uconn.Handshake(); err != nil {\n\t\t\t\t\t_ = rawConn.Close()\n\t\t\t\t\treturn nil, err\n\t\t\t\t}\n\t\t\t\treturn uconn, nil\n\t\t\t},\n\t\t}\n'''
edit("internal/utils/network/ws_dialer.go", old_wss, new_wss)

print("custom Backhaul v2 patch applied successfully")

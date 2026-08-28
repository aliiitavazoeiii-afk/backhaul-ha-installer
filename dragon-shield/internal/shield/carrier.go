package shield

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/quic-go/quic-go"
	"github.com/quic-go/webtransport-go"
)

const webSocketFallbackPort = "8443"

type carrier interface {
	Kind() string
	Send(context.Context, []byte) error
	Recv(context.Context) ([]byte, error)
	Close() error
}

// basicPacketConn deliberately exposes only net.PacketConn. In particular it
// does not expose the OOBCapablePacketConn methods of *net.UDPConn.
type basicPacketConn struct {
	net.PacketConn
}

type wtCarrier struct {
	sess *webtransport.Session
	tr   *webtransport.Transport
	pc   net.PacketConn
}

func (c *wtCarrier) Kind() string { return "webtransport" }
func (c *wtCarrier) Send(_ context.Context, b []byte) error {
	return c.sess.SendDatagram(b)
}
func (c *wtCarrier) Recv(ctx context.Context) ([]byte, error) {
	return c.sess.ReceiveDatagram(ctx)
}
func (c *wtCarrier) Close() error {
	_ = c.sess.CloseWithError(0, "")
	if c.tr != nil {
		_ = c.tr.Close()
	}
	if c.pc != nil {
		return c.pc.Close()
	}
	return nil
}

type wsCarrier struct {
	conn *websocket.Conn
}

func (c *wsCarrier) Kind() string { return "websocket" }
func (c *wsCarrier) Send(ctx context.Context, b []byte) error {
	return c.conn.Write(ctx, websocket.MessageBinary, b)
}
func (c *wsCarrier) Recv(ctx context.Context) ([]byte, error) {
	typ, b, err := c.conn.Read(ctx)
	if err != nil {
		return nil, err
	}
	if typ != websocket.MessageBinary {
		return nil, errors.New("unexpected websocket message type")
	}
	return b, nil
}
func (c *wsCarrier) Close() error {
	return c.conn.Close(websocket.StatusNormalClosure, "")
}

func transportServer(server string) string {
	host, _, err := net.SplitHostPort(server)
	if err != nil {
		return net.JoinHostPort(server, webSocketFallbackPort)
	}
	return net.JoinHostPort(host, webSocketFallbackPort)
}

func dialWebTransport(ctx context.Context, cfg ClientConfig) (carrier, error) {
	headers, err := newAuthHeaders(cfg.ClientID, cfg.Token, cfg.WebTransportPath)
	if err != nil {
		return nil, err
	}

	var packetConn net.PacketConn
	tr := &webtransport.Transport{
		TLSClientConfig: &tls.Config{
			ServerName: cfg.ServerName,
			MinVersion: tls.VersionTLS13,
		},
		QUICConfig: &quic.Config{
			EnableDatagrams:                  true,
			EnableStreamResetPartialDelivery: true,
			KeepAlivePeriod:                  15 * time.Second,
			MaxIdleTimeout:                   45 * time.Second,
			HandshakeIdleTimeout:             5 * time.Second,
			DisablePathMTUDiscovery:          true,
		},
		DialAddr: func(ctx context.Context, _ string, tlsCfg *tls.Config, qcfg *quic.Config) (*quic.Conn, error) {
			pc, err := net.ListenPacket("udp4", ":0")
			if err != nil {
				return nil, fmt.Errorf("listen local QUIC socket: %w", err)
			}
			remote, err := net.ResolveUDPAddr("udp4", veilLoopbackAddr)
			if err != nil {
				_ = pc.Close()
				return nil, fmt.Errorf("resolve local veil endpoint: %w", err)
			}
			packetConn = pc
			conn, err := quic.DialEarly(ctx, &basicPacketConn{PacketConn: pc}, remote, tlsCfg, qcfg)
			if err != nil {
				_ = pc.Close()
				packetConn = nil
				return nil, err
			}
			return conn, nil
		},
	}
	// Keep the public host in the URL for the HTTP/3 authority and TLS SNI. The
	// actual UDP packets are sent to the local encrypted veil by DialAddr above.
	url := "https://" + transportServer(cfg.Server) + cfg.WebTransportPath
	rsp, sess, err := tr.Dial(ctx, url, headers)
	if err != nil {
		_ = tr.Close()
		if packetConn != nil {
			_ = packetConn.Close()
		}
		return nil, err
	}
	if rsp.StatusCode < 200 || rsp.StatusCode >= 300 {
		_ = sess.CloseWithError(0, "")
		_ = tr.Close()
		if packetConn != nil {
			_ = packetConn.Close()
		}
		return nil, fmt.Errorf("webtransport HTTP status %d", rsp.StatusCode)
	}
	return &wtCarrier{sess: sess, tr: tr, pc: packetConn}, nil
}

func dialWebSocket(ctx context.Context, cfg ClientConfig) (carrier, error) {
	headers, err := newAuthHeaders(cfg.ClientID, cfg.Token, cfg.WebSocketPath)
	if err != nil {
		return nil, err
	}
	url := "wss://" + transportServer(cfg.Server) + cfg.WebSocketPath
	conn, rsp, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		HTTPHeader:      headers,
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		if rsp != nil {
			return nil, fmt.Errorf("websocket dial: HTTP %d: %w", rsp.StatusCode, err)
		}
		return nil, err
	}
	conn.SetReadLimit(1 << 20)
	return &wsCarrier{conn: conn}, nil
}

func dialCarrier(ctx context.Context, cfg ClientConfig, preferWT bool) (carrier, error) {
	try := func(fn func(context.Context, ClientConfig) (carrier, error)) (carrier, error) {
		attemptCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		defer cancel()
		return fn(attemptCtx, cfg)
	}
	mode := strings.ToLower(cfg.Mode)
	switch mode {
	case "webtransport":
		return try(dialWebTransport)
	case "websocket":
		return try(dialWebSocket)
	case "auto":
		var first, second func(context.Context, ClientConfig) (carrier, error)
		var firstName, secondName string
		if preferWT {
			first, second = dialWebTransport, dialWebSocket
			firstName, secondName = "webtransport", "websocket"
		} else {
			first, second = dialWebSocket, dialWebTransport
			firstName, secondName = "websocket", "webtransport"
		}
		c, err1 := try(first)
		if err1 == nil {
			return c, nil
		}
		log.Printf("dragon-shield: %s dial failed, trying %s: %v", firstName, secondName, err1)
		c, err2 := try(second)
		if err2 == nil {
			return c, nil
		}
		return nil, fmt.Errorf("both carriers failed: primary=%v; fallback=%v", err1, err2)
	default:
		return nil, fmt.Errorf("unsupported mode %q", mode)
	}
}

func genericNotFound(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	http.Error(w, "404 page not found", http.StatusNotFound)
}

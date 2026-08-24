package tunnel

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-tunnel/internal/proto"
	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-tunnel/internal/ws"
)

type Client struct {
	cfg         ClientConfig
	targets     map[uint16]string
	nextSession atomic.Uint64
}

func LoadClientConfig(path string) (ClientConfig, error) {
	var c ClientConfig
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, err
	}
	if c.RemoteAddr == "" {
		return c, errors.New("remote_addr required")
	}
	if c.Scheme == "" {
		c.Scheme = "wss"
	}
	if c.Scheme != "wss" && c.Scheme != "ws" {
		return c, errors.New("scheme must be ws or wss")
	}
	if c.Token == "" || len(c.Token) < 32 {
		return c, errors.New("token missing/too short")
	}
	if !strings.HasPrefix(c.PathPrefix, "/") || len(c.PathPrefix) < 16 {
		return c, errors.New("path_prefix invalid")
	}
	if c.Pool <= 0 {
		c.Pool = 4
	}
	if c.Pool > 32 {
		return c, errors.New("pool too large")
	}
	if len(c.Targets) == 0 {
		return c, errors.New("no targets configured")
	}
	seen := map[uint16]bool{}
	for _, t := range c.Targets {
		if t.ID == 0 || t.Address == "" {
			return c, errors.New("target requires id/address")
		}
		if seen[t.ID] {
			return c, fmt.Errorf("duplicate target id %d", t.ID)
		}
		seen[t.ID] = true
	}
	return c, nil
}
func NewClient(c ClientConfig) *Client {
	m := map[uint16]string{}
	for _, t := range c.Targets {
		m[t.ID] = t.Address
	}
	return &Client{cfg: c, targets: m}
}

func (cl *Client) Run(ctx context.Context) error {
	errCh := make(chan error, cl.cfg.Pool)
	for i := 0; i < cl.cfg.Pool; i++ {
		go cl.sessionLoop(ctx, i, errCh)
	}
	select {
	case <-ctx.Done():
		return nil
	case err := <-errCh:
		return err
	}
}

func (cl *Client) sessionLoop(ctx context.Context, slot int, errCh chan<- error) {
	backoff := time.Second
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		c, err := cl.connect(ctx)
		if err != nil {
			log.Printf("carrier[%d] connect: %v", slot, err)
			select {
			case <-time.After(backoff):
			case <-ctx.Done():
				return
			}
			if backoff < 15*time.Second {
				backoff *= 2
			}
			continue
		}
		backoff = time.Second
		log.Printf("carrier[%d] online", slot)
		cl.readSession(ctx, c)
		c.close()
		log.Printf("carrier[%d] offline; reconnecting", slot)
	}
}

func (cl *Client) connect(ctx context.Context) (*carrier, error) {
	host, port, err := net.SplitHostPort(cl.cfg.RemoteAddr)
	if err != nil {
		return nil, err
	}
	dialHost := host
	if cl.cfg.EdgeIP != "" {
		dialHost = cl.cfg.EdgeIP
	}
	d := net.Dialer{Timeout: cl.cfg.dialTimeout(), KeepAlive: 30 * time.Second}
	raw, err := d.DialContext(ctx, "tcp", net.JoinHostPort(dialHost, port))
	if err != nil {
		return nil, err
	}
	var conn net.Conn = raw
	if cl.cfg.Scheme == "wss" {
		sni := cl.cfg.TLSServerName
		if sni == "" {
			sni = host
		}
		tc := tls.Client(raw, &tls.Config{ServerName: sni, InsecureSkipVerify: cl.cfg.TLSSkipVerify, MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"}})
		hctx, cancel := context.WithTimeout(ctx, cl.cfg.dialTimeout())
		defer cancel()
		if err := tc.HandshakeContext(hctx); err != nil {
			raw.Close()
			return nil, err
		}
		conn = tc
	}
	path := strings.TrimRight(cl.cfg.PathPrefix, "/") + "/" + randomHex(12)
	origin := cl.cfg.Origin
	if origin == "" {
		origin = "https://" + host
	}
	wc, err := ws.ClientHandshake(conn, host, path, cl.cfg.Token, origin)
	if err != nil {
		conn.Close()
		return nil, err
	}
	wc.MaxPayload = proto.HeaderSize + proto.MaxData
	id := cl.nextSession.Add(1)
	c := newCarrier(id, wc)
	if err := c.send(proto.Frame{Type: proto.TypeHello, Payload: []byte("AEGIS/1")}); err != nil {
		c.close()
		return nil, err
	}
	go cl.sessionKeepalive(c)
	return c, nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

func (cl *Client) readSession(ctx context.Context, c *carrier) {
	for {
		b, err := c.w.ReadBinary()
		if err != nil {
			return
		}
		f, err := proto.Decode(b)
		if err != nil {
			return
		}
		c.touch()
		switch f.Type {
		case proto.TypeOpen:
			addr, ok := cl.targets[f.TargetID]
			if !ok {
				_ = c.send(proto.Frame{Type: proto.TypeClose, StreamID: f.StreamID})
				continue
			}
			d := net.Dialer{Timeout: cl.cfg.dialTimeout(), KeepAlive: 30 * time.Second}
			conn, err := d.DialContext(ctx, "tcp", addr)
			if err != nil {
				_ = c.send(proto.Frame{Type: proto.TypeClose, StreamID: f.StreamID})
				continue
			}
			if _, err := c.addStream(f.StreamID, conn); err != nil {
				conn.Close()
				_ = c.send(proto.Frame{Type: proto.TypeClose, StreamID: f.StreamID})
				continue
			}
			go copyConnToCarrier(c, f.StreamID, conn)
		case proto.TypeData:
			st := c.getStream(f.StreamID)
			if st == nil {
				continue
			}
			if !st.enqueue(f.Payload) {
				_ = c.send(proto.Frame{Type: proto.TypeClose, StreamID: f.StreamID})
				c.delStream(f.StreamID)
			}
		case proto.TypeClose:
			c.delStream(f.StreamID)
		case proto.TypePing:
			_ = c.send(proto.Frame{Type: proto.TypePong, Payload: f.Payload})
		case proto.TypePong:
		default:
			return
		}
	}
}
func (cl *Client) sessionKeepalive(c *carrier) {
	interval := cl.cfg.keepAlive()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	timeout := 3 * interval
	for {
		select {
		case <-ticker.C:
			if time.Since(time.Unix(0, c.lastSeen.Load())) > timeout {
				c.close()
				return
			}
			if err := c.send(proto.Frame{Type: proto.TypePing, Payload: []byte("k")}); err != nil {
				c.close()
				return
			}
		case <-c.closed:
			return
		}
	}
}

func ValidateURLBase(raw string) error { _, err := url.Parse(raw); return err }

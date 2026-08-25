package tunnel

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-tunnel/internal/proto"
	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-tunnel/internal/ws"
)

type Client struct {
	cfg         ClientConfig
	targets     map[uint16]string
	nextSession atomic.Uint64
	healthy     atomic.Bool
	sessionsMu  sync.Mutex
	sessions    map[uint64]*carrier
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
	cl := &Client{cfg: c, targets: m, sessions: make(map[uint64]*carrier)}
	if c.HealthTarget == "" {
		cl.healthy.Store(true)
	}
	return cl
}

func (cl *Client) Run(ctx context.Context) error {
	var wg sync.WaitGroup
	if cl.cfg.HealthTarget != "" {
		wg.Add(1)
		go func() {
			defer wg.Done()
			cl.healthLoop(ctx)
		}()
	}
	for i := 0; i < cl.cfg.Pool; i++ {
		wg.Add(1)
		go func(slot int) {
			defer wg.Done()
			cl.sessionLoop(ctx, slot)
		}(i)
	}
	<-ctx.Done()
	cl.closeAllSessions()
	wg.Wait()
	return nil
}

func (cl *Client) healthLoop(ctx context.Context) {
	interval := cl.cfg.healthInterval()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	fails, rises := 0, 0
	check := func() {
		ok := cl.probeLocalTarget()
		if ok {
			fails = 0
			rises++
			if !cl.healthy.Load() && rises >= 2 {
				cl.healthy.Store(true)
				log.Printf("local target health UP: %s", cl.cfg.HealthTarget)
			}
			return
		}
		rises = 0
		fails++
		if cl.healthy.Load() && fails >= 2 {
			cl.healthy.Store(false)
			log.Printf("local target health DOWN: %s; closing carriers", cl.cfg.HealthTarget)
			cl.closeAllSessions()
		}
	}
	check()
	for {
		select {
		case <-ticker.C:
			check()
		case <-ctx.Done():
			return
		}
	}
}

func (cl *Client) probeLocalTarget() bool {
	timeout := cl.cfg.dialTimeout()
	if timeout > 2*time.Second {
		timeout = 2 * time.Second
	}
	c, err := net.DialTimeout("tcp", cl.cfg.HealthTarget, timeout)
	if err != nil {
		return false
	}
	_ = c.Close()
	return true
}

func (cl *Client) addSession(c *carrier) {
	cl.sessionsMu.Lock()
	cl.sessions[c.id] = c
	cl.sessionsMu.Unlock()
}

func (cl *Client) removeSession(c *carrier) {
	cl.sessionsMu.Lock()
	delete(cl.sessions, c.id)
	cl.sessionsMu.Unlock()
}

func (cl *Client) closeAllSessions() {
	cl.sessionsMu.Lock()
	ss := make([]*carrier, 0, len(cl.sessions))
	for _, c := range cl.sessions {
		ss = append(ss, c)
	}
	cl.sessionsMu.Unlock()
	for _, c := range ss {
		c.close()
	}
}

func (cl *Client) waitHealthy(ctx context.Context) bool {
	for !cl.healthy.Load() {
		if !sleepContext(ctx, 250*time.Millisecond) {
			return false
		}
	}
	return true
}

func (cl *Client) sessionLoop(ctx context.Context, slot int) {
	backoff := time.Second
	if !sleepContext(ctx, jitterDuration(time.Duration(slot)*120*time.Millisecond+80*time.Millisecond)) {
		return
	}
	for {
		if !cl.waitHealthy(ctx) {
			return
		}
		started := time.Now()
		c, err := cl.connect(ctx)
		if err != nil {
			log.Printf("carrier[%d] connect: %v", slot, err)
			if !sleepContext(ctx, jitterDuration(backoff)) {
				return
			}
			backoff = growBackoff(backoff)
			continue
		}
		cl.addSession(c)
		log.Printf("carrier[%d] online", slot)
		cl.readSession(ctx, c)
		cl.removeSession(c)
		c.close()
		lived := time.Since(started)
		log.Printf("carrier[%d] offline after %s", slot, lived.Round(time.Millisecond))
		if lived >= 30*time.Second {
			backoff = time.Second
		} else {
			backoff = growBackoff(backoff)
		}
		if !sleepContext(ctx, jitterDuration(backoff)) {
			return
		}
	}
}

func growBackoff(d time.Duration) time.Duration {
	if d < time.Second {
		d = time.Second
	}
	d *= 2
	if d > 15*time.Second {
		return 15 * time.Second
	}
	return d
}

func jitterDuration(base time.Duration) time.Duration {
	if base <= 0 {
		return 0
	}
	var b [2]byte
	if _, err := rand.Read(b[:]); err != nil {
		return base
	}
	fraction := 0.75 + (float64(binary.BigEndian.Uint16(b[:]))/65535.0)*0.50
	return time.Duration(float64(base) * fraction)
}

func sleepContext(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
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
		if err := tc.HandshakeContext(hctx); err != nil {
			cancel()
			_ = raw.Close()
			return nil, err
		}
		cancel()
		conn = tc
	}
	suffix, err := randomHexSecure(12)
	if err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("path randomness: %w", err)
	}
	path := strings.TrimRight(cl.cfg.PathPrefix, "/") + "/" + suffix
	origin := cl.cfg.Origin
	if origin == "" {
		origin = "https://" + host
	}
	wc, err := ws.ClientHandshake(conn, host, path, cl.cfg.Token, origin)
	if err != nil {
		_ = conn.Close()
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

func randomHexSecure(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func (cl *Client) readSession(ctx context.Context, c *carrier) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
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
			st, err := c.addStream(f.StreamID, conn)
			if err != nil {
				_ = conn.Close()
				_ = c.send(proto.Frame{Type: proto.TypeClose, StreamID: f.StreamID})
				continue
			}
			st.startWriter()
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

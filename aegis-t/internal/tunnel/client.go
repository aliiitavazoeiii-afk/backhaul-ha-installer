package tunnel

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Client struct {
	cfg ClientConfig

	healthy atomic.Bool
	ready   atomic.Int64
	active  atomic.Int64

	idleMu sync.Mutex
	idle   map[net.Conn]struct{}

	activeWG    sync.WaitGroup
	activeMu    sync.Mutex
	activeConns map[net.Conn]struct{}
}

func NewClient(cfg ClientConfig) *Client {
	return &Client{cfg: cfg, idle: make(map[net.Conn]struct{}), activeConns: make(map[net.Conn]struct{})}
}

func (c *Client) Run(ctx context.Context) error {
	c.healthy.Store(c.probeTarget())
	go c.healthLoop(ctx)

	var workers sync.WaitGroup
	for i := 0; i < c.cfg.Pool; i++ {
		workers.Add(1)
		go func(slot int) {
			defer workers.Done()
			c.worker(ctx, slot)
		}(i)
	}
	<-ctx.Done()
	c.closeIdle()
	c.closeActive()
	workers.Wait()
	c.closeActive()
	c.activeWG.Wait()
	return nil
}

func (c *Client) worker(ctx context.Context, slot int) {
	if !sleepContext(ctx, jitter(time.Duration(slot)*25*time.Millisecond+50*time.Millisecond)) {
		return
	}
	backoff := 500 * time.Millisecond
	for {
		if !c.waitHealthy(ctx) {
			return
		}
		conn, br, err := c.connectCarrier(ctx)
		if err != nil {
			log.Printf("carrier[%d] connect: %v", slot, err)
			if !sleepContext(ctx, jitter(backoff)) {
				return
			}
			backoff = growBackoff(backoff)
			continue
		}
		backoff = 500 * time.Millisecond
		c.addIdle(conn)
		c.ready.Add(1)
		log.Printf("carrier[%d] ready total=%d", slot, c.ready.Load())

		_ = conn.SetReadDeadline(time.Now().Add(4 * time.Minute))
		cmd, err := br.ReadByte()
		c.removeIdle(conn)
		c.ready.Add(-1)
		if err != nil {
			_ = conn.Close()
			if !sleepContext(ctx, jitter(100*time.Millisecond)) {
				return
			}
			continue
		}
		if cmd != cmdOpen {
			_ = conn.Close()
			continue
		}
		target, err := net.DialTimeout("tcp", c.cfg.Target, c.cfg.dialTimeout())
		if err != nil {
			_, _ = conn.Write([]byte{ackFail})
			_ = conn.Close()
			continue
		}
		tuneTCP(target)
		if _, err := conn.Write([]byte{ackOK}); err != nil {
			_ = conn.Close()
			_ = target.Close()
			continue
		}
		_ = conn.SetDeadline(time.Time{})
		select {
		case <-ctx.Done():
			_ = conn.Close()
			_ = target.Close()
			return
		default:
		}
		carrierConn := &bufferedConn{Conn: conn, r: br}
		c.registerActive(carrierConn, target)
		c.active.Add(1)
		c.activeWG.Add(1)
		go func() {
			defer c.activeWG.Done()
			defer c.active.Add(-1)
			defer c.unregisterActive(carrierConn, target)
			bridge(carrierConn, target)
		}()

		// Replenish the warm pool immediately; the active bridge owns this carrier now.
		if !sleepContext(ctx, jitter(20*time.Millisecond)) {
			return
		}
	}
}

func (c *Client) connectCarrier(ctx context.Context) (net.Conn, *bufio.Reader, error) {
	host, port, err := net.SplitHostPort(c.cfg.RemoteAddr)
	if err != nil {
		return nil, nil, err
	}
	dialHost := host
	if c.cfg.EdgeIP != "" {
		dialHost = c.cfg.EdgeIP
	}
	d := net.Dialer{Timeout: c.cfg.dialTimeout(), KeepAlive: 30 * time.Second}
	raw, err := d.DialContext(ctx, "tcp", net.JoinHostPort(dialHost, port))
	if err != nil {
		return nil, nil, err
	}
	tuneTCP(raw)

	uc := tls.Client(raw, &tls.Config{ServerName: c.cfg.TLSServerName, MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"}})
	hctx, cancel := context.WithTimeout(ctx, c.cfg.dialTimeout())
	err = uc.HandshakeContext(hctx)
	cancel()
	if err != nil {
		_ = raw.Close()
		return nil, nil, err
	}

	suffix, err := randomHex(12)
	if err != nil {
		_ = uc.Close()
		return nil, nil, err
	}
	path := strings.TrimRight(c.cfg.PathPrefix, "/") + "/" + suffix
	unix, nonce, sig, err := newAuth(c.cfg.Token, path)
	if err != nil {
		_ = uc.Close()
		return nil, nil, err
	}
	pad, err := randomPadding(c.cfg.PaddingMin, c.cfg.PaddingMax)
	if err != nil {
		_ = uc.Close()
		return nil, nil, err
	}

	req := "POST " + path + " HTTP/1.1\r\n" +
		"Host: " + c.cfg.TLSServerName + "\r\n" +
		"User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36\r\n" +
		"Accept: */*\r\n" +
		"Accept-Language: en-US,en;q=0.9\r\n" +
		"Cache-Control: no-cache\r\n" +
		"Pragma: no-cache\r\n" +
		"Content-Length: 0\r\n" +
		"X-Request-Time: " + unix + "\r\n" +
		"X-Request-ID: " + nonce + "\r\n" +
		"X-Request-Signature: " + sig + "\r\n" +
		"X-Client-Data: " + pad + "\r\n" +
		"Connection: keep-alive\r\n\r\n"

	_ = uc.SetDeadline(time.Now().Add(c.cfg.dialTimeout()))
	if _, err := io.WriteString(uc, req); err != nil {
		_ = uc.Close()
		return nil, nil, err
	}
	br := bufio.NewReader(uc)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodPost})
	if err != nil {
		_ = uc.Close()
		return nil, nil, err
	}
	if resp.StatusCode != http.StatusOK {
		_ = resp.Body.Close()
		_ = uc.Close()
		return nil, nil, fmt.Errorf("carrier rejected: %s", resp.Status)
	}
	// The server hijacks immediately after the headers. Do not read resp.Body.
	_ = uc.SetDeadline(time.Time{})
	return uc, br, nil
}

func (c *Client) healthLoop(ctx context.Context) {
	tick := time.NewTicker(c.cfg.healthInterval())
	defer tick.Stop()
	fails, rises := 0, 0
	for {
		select {
		case <-tick.C:
			ok := c.probeTarget()
			if ok {
				fails = 0
				rises++
				if !c.healthy.Load() && rises >= 2 {
					c.healthy.Store(true)
					log.Printf("local target health UP: %s", c.cfg.HealthTarget)
				}
			} else {
				rises = 0
				fails++
				if c.healthy.Load() && fails >= 2 {
					c.healthy.Store(false)
					log.Printf("local target health DOWN: %s; closing idle carriers", c.cfg.HealthTarget)
					c.closeIdle()
				}
			}
		case <-ctx.Done():
			return
		}
	}
}

func (c *Client) probeTarget() bool {
	d := c.cfg.dialTimeout()
	if d > 2*time.Second {
		d = 2 * time.Second
	}
	x, err := net.DialTimeout("tcp", c.cfg.HealthTarget, d)
	if err != nil {
		return false
	}
	_ = x.Close()
	return true
}

func (c *Client) waitHealthy(ctx context.Context) bool {
	for !c.healthy.Load() {
		if !sleepContext(ctx, 250*time.Millisecond) {
			return false
		}
	}
	return true
}

func (c *Client) addIdle(conn net.Conn) {
	c.idleMu.Lock()
	c.idle[conn] = struct{}{}
	c.idleMu.Unlock()
}

func (c *Client) removeIdle(conn net.Conn) {
	c.idleMu.Lock()
	delete(c.idle, conn)
	c.idleMu.Unlock()
}

func (c *Client) closeIdle() {
	c.idleMu.Lock()
	xs := make([]net.Conn, 0, len(c.idle))
	for x := range c.idle {
		xs = append(xs, x)
	}
	c.idle = make(map[net.Conn]struct{})
	c.idleMu.Unlock()
	for _, x := range xs {
		_ = x.Close()
	}
}

func (c *Client) registerActive(xs ...net.Conn) {
	c.activeMu.Lock()
	for _, x := range xs {
		c.activeConns[x] = struct{}{}
	}
	c.activeMu.Unlock()
}

func (c *Client) unregisterActive(xs ...net.Conn) {
	c.activeMu.Lock()
	for _, x := range xs {
		delete(c.activeConns, x)
	}
	c.activeMu.Unlock()
}

func (c *Client) closeActive() {
	c.activeMu.Lock()
	xs := make([]net.Conn, 0, len(c.activeConns))
	for x := range c.activeConns {
		xs = append(xs, x)
	}
	c.activeMu.Unlock()
	for _, x := range xs {
		_ = x.Close()
	}
}

func growBackoff(d time.Duration) time.Duration {
	if d < 500*time.Millisecond {
		d = 500 * time.Millisecond
	}
	d *= 2
	if d > 12*time.Second {
		d = 12 * time.Second
	}
	return d
}

func jitter(base time.Duration) time.Duration {
	if base <= 0 {
		return 0
	}
	var b [2]byte
	if _, err := rand.Read(b[:]); err != nil {
		return base
	}
	v := int(b[0])<<8 | int(b[1])
	frac := 0.75 + (float64(v)/65535.0)*0.5
	return time.Duration(float64(base) * frac)
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

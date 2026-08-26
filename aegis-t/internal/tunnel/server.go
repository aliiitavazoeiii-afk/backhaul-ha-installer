package tunnel

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	cmdOpen = byte(0x51)
	ackOK   = byte(0x52)
	ackFail = byte(0x53)
)

type idleCarrier struct {
	conn    net.Conn
	reader  *bufio.Reader
	created time.Time
	once    sync.Once
}

func (c *idleCarrier) close() { c.once.Do(func() { _ = c.conn.Close() }) }

type Server struct {
	cfg      ServerConfig
	replay   *replayCache
	idle     chan *idleCarrier
	ready    atomic.Int64
	active   atomic.Int64
	accepted atomic.Uint64
	rejected atomic.Uint64

	readyMu sync.Mutex
	readyLn net.Listener
}

func NewServer(cfg ServerConfig) *Server {
	return &Server{cfg: cfg, replay: newReplayCache(), idle: make(chan *idleCarrier, cfg.MaxIdle)}
}

func (s *Server) Run(ctx context.Context) error {
	cert, err := tls.LoadX509KeyPair(s.cfg.CertFile, s.cfg.KeyFile)
	if err != nil {
		return fmt.Errorf("load certificate: %w", err)
	}
	rawCarrier, err := net.Listen("tcp", s.cfg.CarrierListen)
	if err != nil {
		return fmt.Errorf("carrier listen: %w", err)
	}
	rawCarrier = &keepAliveListener{Listener: rawCarrier}
	tlsLn := tls.NewListener(rawCarrier, &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{"http/1.1"},
	})

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleHTTP)
	hs := &http.Server{Handler: mux, ReadHeaderTimeout: 8 * time.Second, IdleTimeout: 0, MaxHeaderBytes: 16 << 10}

	userLn, err := net.Listen("tcp", s.cfg.UserListen)
	if err != nil {
		_ = tlsLn.Close()
		return fmt.Errorf("user listen: %w", err)
	}

	errCh := make(chan error, 3)
	go func() {
		log.Printf("carrier TLS listener %s host=%s prefix=%s", s.cfg.CarrierListen, s.cfg.Host, s.cfg.PathPrefix)
		if err := hs.Serve(tlsLn); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()
	go func() { errCh <- s.acceptUsers(ctx, userLn) }()
	go s.expireLoop(ctx)

	select {
	case <-ctx.Done():
		_ = userLn.Close()
		_ = tlsLn.Close()
		shutCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_ = hs.Shutdown(shutCtx)
		cancel()
		s.closeReadiness()
		s.drainIdle()
		return nil
	case err := <-errCh:
		_ = userLn.Close()
		_ = tlsLn.Close()
		s.closeReadiness()
		s.drainIdle()
		return err
	}
}

func (s *Server) handleHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !strings.HasPrefix(r.URL.Path, strings.TrimRight(s.cfg.PathPrefix, "/")+"/") || !strings.EqualFold(r.Host, s.cfg.Host) {
		s.fallback(w)
		return
	}
	if err := verifyAuth(s.cfg.Token, r.Header.Get("X-Request-Time"), r.Header.Get("X-Request-ID"), r.URL.Path, r.Header.Get("X-Request-Signature"), time.Now(), s.replay); err != nil {
		s.rejected.Add(1)
		s.fallback(w)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	conn, rw, err := hj.Hijack()
	if err != nil {
		return
	}
	tuneTLSUnderlying(conn)
	if _, err := rw.WriteString("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"); err != nil {
		_ = conn.Close()
		return
	}
	if err := rw.Flush(); err != nil {
		_ = conn.Close()
		return
	}
	c := &idleCarrier{conn: conn, reader: rw.Reader, created: time.Now()}
	select {
	case s.idle <- c:
		s.ready.Add(1)
		s.accepted.Add(1)
		s.syncReadiness()
	default:
		c.close()
		s.rejected.Add(1)
	}
}

func (s *Server) fallback(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusNotFound)
	_, _ = w.Write([]byte("<!doctype html><html><head><title>404 Not Found</title></head><body><h1>Not Found</h1></body></html>"))
}

func (s *Server) acceptUsers(ctx context.Context, ln net.Listener) error {
	log.Printf("user listener %s", s.cfg.UserListen)
	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return nil
			default:
				return err
			}
		}
		tuneTCP(conn)
		go s.handleUser(ctx, conn)
	}
}

func (s *Server) handleUser(ctx context.Context, user net.Conn) {
	defer func() {
		if user != nil {
			_ = user.Close()
		}
	}()
	deadline := time.Now().Add(s.cfg.acquireTimeout())
	for attempts := 0; attempts < 4; attempts++ {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return
		}
		timer := time.NewTimer(remaining)
		var c *idleCarrier
		select {
		case c = <-s.idle:
			if !timer.Stop() {
				<-timer.C
			}
			s.ready.Add(-1)
			s.syncReadiness()
		case <-timer.C:
			return
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return
		}
		if time.Since(c.created) > s.cfg.carrierTTL() {
			c.close()
			continue
		}
		_ = c.conn.SetDeadline(time.Now().Add(5 * time.Second))
		if _, err := c.conn.Write([]byte{cmdOpen}); err != nil {
			c.close()
			continue
		}
		ack, err := c.reader.ReadByte()
		if err != nil || ack != ackOK {
			c.close()
			continue
		}
		_ = c.conn.SetDeadline(time.Time{})
		carrierConn := &bufferedConn{Conn: c.conn, r: c.reader}
		s.active.Add(1)
		bridge(user, carrierConn)
		s.active.Add(-1)
		user = nil
		return
	}
}

func (s *Server) expireLoop(ctx context.Context) {
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-tick.C:
			s.expireOnePass()
		case <-ctx.Done():
			return
		}
	}
}

func (s *Server) expireOnePass() {
	n := len(s.idle)
	for i := 0; i < n; i++ {
		select {
		case c := <-s.idle:
			s.ready.Add(-1)
			if time.Since(c.created) > s.cfg.carrierTTL() {
				c.close()
			} else {
				select {
				case s.idle <- c:
					s.ready.Add(1)
				default:
					c.close()
				}
			}
		default:
			i = n
		}
	}
	s.syncReadiness()
}

func (s *Server) syncReadiness() {
	want := int(s.ready.Load()) >= s.cfg.MinReady
	s.readyMu.Lock()
	defer s.readyMu.Unlock()
	if want && s.readyLn == nil {
		ln, err := net.Listen("tcp", s.cfg.ReadinessListen)
		if err != nil {
			log.Printf("readiness listen failed: %v", err)
			return
		}
		s.readyLn = ln
		log.Printf("readiness UP ready=%d", s.ready.Load())
		go func(l net.Listener) {
			for {
				c, err := l.Accept()
				if err != nil {
					return
				}
				_ = c.Close()
			}
		}(ln)
	} else if !want && s.readyLn != nil {
		_ = s.readyLn.Close()
		s.readyLn = nil
		log.Printf("readiness DOWN ready=%d", s.ready.Load())
	}
}

func (s *Server) closeReadiness() {
	s.readyMu.Lock()
	defer s.readyMu.Unlock()
	if s.readyLn != nil {
		_ = s.readyLn.Close()
		s.readyLn = nil
	}
}

func (s *Server) drainIdle() {
	for {
		select {
		case c := <-s.idle:
			c.close()
		default:
			return
		}
	}
}

type keepAliveListener struct{ net.Listener }

func (l *keepAliveListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	tuneTCP(c)
	return c, nil
}

func tuneTLSUnderlying(c net.Conn) {
	if tc, ok := c.(*tls.Conn); ok {
		tuneTCP(tc.NetConn())
	} else {
		tuneTCP(c)
	}
}

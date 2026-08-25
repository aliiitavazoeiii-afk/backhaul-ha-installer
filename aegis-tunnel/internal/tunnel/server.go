package tunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-tunnel/internal/proto"
	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-tunnel/internal/ws"
)

const maxServerCarriers = 32

type Server struct {
	cfg         ServerConfig
	httpServer  *http.Server
	sessionsMu  sync.RWMutex
	sessions    []*carrier
	nextSession atomic.Uint64
	nextStream  atomic.Uint32
	rr          atomic.Uint64
	listeners   []net.Listener
	readyMu     sync.Mutex
	readyLn     net.Listener
}

func LoadServerConfig(path string) (ServerConfig, error) {
	var c ServerConfig
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, err
	}
	if c.Bind == "" {
		c.Bind = "127.0.0.1:18080"
	}
	if c.Token == "" || len(c.Token) < 32 {
		return c, errors.New("server token missing/too short")
	}
	if !strings.HasPrefix(c.PathPrefix, "/") || len(c.PathPrefix) < 16 {
		return c, errors.New("path_prefix invalid")
	}
	if len(c.Listeners) == 0 {
		return c, errors.New("no listeners configured")
	}
	seen := map[uint16]bool{}
	for _, l := range c.Listeners {
		if l.Listen == "" || l.TargetID == 0 {
			return c, errors.New("listener requires listen and target_id")
		}
		if seen[l.TargetID] {
			return c, fmt.Errorf("duplicate target_id %d", l.TargetID)
		}
		seen[l.TargetID] = true
	}
	return c, nil
}

func NewServer(c ServerConfig) *Server { return &Server{cfg: c} }

func (s *Server) Run(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleHTTP)
	s.httpServer = &http.Server{
		Addr:              s.cfg.Bind,
		Handler:           mux,
		ReadHeaderTimeout: 8 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	errCh := make(chan error, 1+len(s.cfg.Listeners))
	go func() {
		log.Printf("aegis server websocket endpoint listening on %s prefix=%s", s.cfg.Bind, s.cfg.PathPrefix)
		if err := s.httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()
	for _, lc := range s.cfg.Listeners {
		lc := lc
		ln, err := net.Listen("tcp", lc.Listen)
		if err != nil {
			return fmt.Errorf("listen %s: %w", lc.Listen, err)
		}
		s.listeners = append(s.listeners, ln)
		go func() { errCh <- s.acceptLocal(ctx, ln, lc) }()
		log.Printf("aegis local forward %s => target_id=%d", lc.Listen, lc.TargetID)
	}

	select {
	case <-ctx.Done():
		s.shutdown()
		return nil
	case err := <-errCh:
		s.shutdown()
		return err
	}
}

func (s *Server) shutdown() {
	for _, ln := range s.listeners {
		_ = ln.Close()
	}
	s.setReadiness(false)
	if s.httpServer != nil {
		shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_ = s.httpServer.Shutdown(shutCtx)
		cancel()
	}
	s.closeAllSessions()
}

func (s *Server) handleHTTP(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(r.URL.Path, s.cfg.PathPrefix+"/") {
		http.NotFound(w, r)
		return
	}
	wc, err := ws.Accept(w, r, s.cfg.Token, s.cfg.PathPrefix+"/")
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	wc.MaxPayload = proto.HeaderSize + proto.MaxData
	_ = wc.SetReadDeadline(time.Now().Add(10 * time.Second))
	id := s.nextSession.Add(1)
	c := newCarrier(id, wc)
	b, err := wc.ReadBinary()
	if err != nil {
		c.close()
		return
	}
	f, err := proto.Decode(b)
	if err != nil || f.Type != proto.TypeHello || string(f.Payload) != "AEGIS/1" {
		c.close()
		return
	}
	_ = wc.SetReadDeadline(time.Time{})
	if !s.addSession(c) {
		c.close()
		log.Printf("carrier %d rejected: carrier limit reached", id)
		return
	}
	log.Printf("carrier %d online from %s", id, wc.RemoteAddr())
	go s.sessionKeepalive(c)
	s.readSession(c)
	s.removeSession(c)
	c.close()
	log.Printf("carrier %d offline", id)
}

func (s *Server) addSession(c *carrier) bool {
	s.sessionsMu.Lock()
	if len(s.sessions) >= maxServerCarriers {
		s.sessionsMu.Unlock()
		return false
	}
	s.sessions = append(s.sessions, c)
	s.sessionsMu.Unlock()
	s.syncReadiness()
	return true
}

func (s *Server) removeSession(c *carrier) {
	s.sessionsMu.Lock()
	out := s.sessions[:0]
	for _, x := range s.sessions {
		if x != c {
			out = append(out, x)
		}
	}
	s.sessions = out
	s.sessionsMu.Unlock()
	s.syncReadiness()
}

func (s *Server) closeAllSessions() {
	s.sessionsMu.Lock()
	ss := append([]*carrier(nil), s.sessions...)
	s.sessions = nil
	s.sessionsMu.Unlock()
	for _, c := range ss {
		c.close()
	}
	s.syncReadiness()
}

func (s *Server) syncReadiness() {
	s.sessionsMu.RLock()
	ready := len(s.sessions) > 0
	s.sessionsMu.RUnlock()
	s.setReadiness(ready)
}

func (s *Server) setReadiness(ready bool) {
	if s.cfg.ReadinessListen == "" {
		return
	}
	s.readyMu.Lock()
	defer s.readyMu.Unlock()
	if ready {
		if s.readyLn != nil {
			return
		}
		ln, err := net.Listen("tcp", s.cfg.ReadinessListen)
		if err != nil {
			log.Printf("readiness listen %s failed: %v", s.cfg.ReadinessListen, err)
			return
		}
		s.readyLn = ln
		log.Printf("readiness UP on %s", s.cfg.ReadinessListen)
		go s.acceptReadiness(ln)
		return
	}
	if s.readyLn != nil {
		ln := s.readyLn
		s.readyLn = nil
		_ = ln.Close()
		log.Printf("readiness DOWN on %s", s.cfg.ReadinessListen)
	}
}

func (s *Server) acceptReadiness(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		_ = conn.Close()
	}
}

func (s *Server) sessionCandidates() []*carrier {
	s.sessionsMu.RLock()
	ss := append([]*carrier(nil), s.sessions...)
	s.sessionsMu.RUnlock()
	if len(ss) < 2 {
		return ss
	}
	start := int(s.rr.Add(1) % uint64(len(ss)))
	out := make([]*carrier, 0, len(ss))
	out = append(out, ss[start:]...)
	out = append(out, ss[:start]...)
	return out
}

func (s *Server) nextStreamID() uint32 {
	for {
		id := s.nextStream.Add(1)
		if id != 0 {
			return id
		}
	}
}

func (s *Server) openLocalStream(conn net.Conn, targetID uint16) (*carrier, uint32, bool) {
	for _, c := range s.sessionCandidates() {
		sid := s.nextStreamID()
		st, err := c.addStream(sid, conn)
		if err != nil {
			continue
		}
		if err := c.send(proto.Frame{Type: proto.TypeOpen, StreamID: sid, TargetID: targetID}); err != nil {
			c.detachStream(sid)
			c.close()
			continue
		}
		st.startWriter()
		return c, sid, true
	}
	return nil, 0, false
}

func (s *Server) acceptLocal(ctx context.Context, ln net.Listener, lc ListenerConfig) error {
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
		c, sid, ok := s.openLocalStream(conn, lc.TargetID)
		if !ok {
			_ = conn.Close()
			continue
		}
		go copyConnToCarrier(c, sid, conn)
	}
}

func (s *Server) readSession(c *carrier) {
	readWindow := 3*s.cfg.keepAlive() + 2*time.Second
	for {
		if err := c.w.SetReadDeadline(time.Now().Add(readWindow)); err != nil {
			return
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

func (s *Server) sessionKeepalive(c *carrier) {
	interval := s.cfg.keepAlive()
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

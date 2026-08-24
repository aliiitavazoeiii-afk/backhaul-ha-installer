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
	s.httpServer = &http.Server{Addr: s.cfg.Bind, Handler: mux, ReadHeaderTimeout: 8 * time.Second, IdleTimeout: 90 * time.Second}

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
		for _, ln := range s.listeners {
			_ = ln.Close()
		}
		shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = s.httpServer.Shutdown(shutCtx)
		s.closeAllSessions()
		return nil
	case err := <-errCh:
		return err
	}
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
	id := s.nextSession.Add(1)
	c := newCarrier(id, wc)
	// First binary message is a version hello. This catches accidental clients
	// without depending on a Backhaul-compatible control channel.
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
	defer s.sessionsMu.Unlock()
	if len(s.sessions) >= maxServerCarriers {
		return false
	}
	s.sessions = append(s.sessions, c)
	return true
}
func (s *Server) removeSession(c *carrier) {
	s.sessionsMu.Lock()
	defer s.sessionsMu.Unlock()
	out := s.sessions[:0]
	for _, x := range s.sessions {
		if x != c {
			out = append(out, x)
		}
	}
	s.sessions = out
}
func (s *Server) closeAllSessions() {
	s.sessionsMu.Lock()
	ss := append([]*carrier(nil), s.sessions...)
	s.sessions = nil
	s.sessionsMu.Unlock()
	for _, c := range ss {
		c.close()
	}
}
func (s *Server) chooseSession() *carrier {
	s.sessionsMu.RLock()
	defer s.sessionsMu.RUnlock()
	if len(s.sessions) == 0 {
		return nil
	}
	n := s.rr.Add(1)
	return s.sessions[int(n%uint64(len(s.sessions)))]
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
		c := s.chooseSession()
		if c == nil {
			_ = conn.Close()
			continue
		}
		sid := s.nextStream.Add(1)
		if sid == 0 {
			sid = s.nextStream.Add(1)
		}
		if _, err := c.addStream(sid, conn); err != nil {
			_ = conn.Close()
			continue
		}
		if err := c.send(proto.Frame{Type: proto.TypeOpen, StreamID: sid, TargetID: lc.TargetID}); err != nil {
			c.delStream(sid)
			continue
		}
		go copyConnToCarrier(c, sid, conn)
	}
}

func (s *Server) readSession(c *carrier) {
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

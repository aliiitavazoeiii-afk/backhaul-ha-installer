package shield

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/quic-go/webtransport-go"
)

type peer struct {
	id       string
	ip       net.IP
	carrier  carrier
	send     chan []byte
	cancel   context.CancelFunc
	drops    atomic.Uint64
	closed   atomic.Bool
	lastSeen atomic.Int64
}

type peerRegistry struct {
	mu   sync.RWMutex
	byIP map[string]*peer
	byID map[string]*peer
}

func newPeerRegistry() *peerRegistry {
	return &peerRegistry{byIP: make(map[string]*peer), byID: make(map[string]*peer)}
}

func (r *peerRegistry) replace(p *peer) {
	r.mu.Lock()
	old := r.byID[p.id]
	if old != nil {
		delete(r.byIP, old.ip.String())
	}
	r.byID[p.id] = p
	r.byIP[p.ip.String()] = p
	r.mu.Unlock()
	if old != nil {
		old.cancel()
		_ = old.carrier.Close()
	}
}

func (r *peerRegistry) remove(p *peer) {
	r.mu.Lock()
	if r.byID[p.id] == p {
		delete(r.byID, p.id)
		delete(r.byIP, p.ip.String())
	}
	r.mu.Unlock()
}

func (r *peerRegistry) getByIP(ip net.IP) *peer {
	r.mu.RLock()
	p := r.byIP[ip.String()]
	r.mu.RUnlock()
	return p
}

func fallbackTCPListenAddr(listen string) string {
	host, _, err := net.SplitHostPort(listen)
	if err != nil {
		return ":" + webSocketFallbackPort
	}
	return net.JoinHostPort(host, webSocketFallbackPort)
}

func RunServer(cfg ServerConfig) error {
	clients := make(map[string]ServerClient, len(cfg.Clients))
	allowedIPs := make(map[string]struct{}, len(cfg.Clients))
	for _, c := range cfg.Clients {
		clients[c.ID] = c
		allowedIPs[net.ParseIP(c.IP).String()] = struct{}{}
	}
	serverIP, _, _ := net.ParseCIDR(cfg.TunCIDR)
	tun, err := openTun(cfg.TunName)
	if err != nil {
		return err
	}
	defer tun.Close()

	replay := newReplayCache()
	registry := newPeerRegistry()
	go serverTunReader(tun, serverIP, allowedIPs, registry, cfg.MTU)

	cert, err := tls.LoadX509KeyPair(cfg.TLSCert, cfg.TLSKey)
	if err != nil {
		return fmt.Errorf("load TLS certificate: %w", err)
	}
	baseTLS := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	}

	h3 := &http3.Server{
		Addr:      cfg.Listen,
		TLSConfig: http3.ConfigureTLSConfig(baseTLS.Clone()),
		QUICConfig: &quic.Config{
			EnableDatagrams:                  true,
			EnableStreamResetPartialDelivery: true,
			KeepAlivePeriod:                  15 * time.Second,
			MaxIdleTimeout:                   45 * time.Second,
			HandshakeIdleTimeout:             5 * time.Second,
		},
	}
	webtransport.ConfigureHTTP3Server(h3)
	wtServer := &webtransport.Server{H3: h3}
	h3Mux := http.NewServeMux()
	h3Mux.HandleFunc(cfg.WebTransportPath, func(w http.ResponseWriter, r *http.Request) {
		cl, err := verifyAuthHeaders(r.Header, cfg.WebTransportPath, clients, replay, time.Now())
		if err != nil {
			genericNotFound(w)
			return
		}
		sess, err := wtServer.Upgrade(w, r)
		if err != nil {
			return
		}
		c := &wtCarrier{sess: sess}
		go servePeer(tun, serverIP, cl, c, registry, cfg.MTU)
	})
	h3Mux.HandleFunc("/", landingHandler)
	h3.Handler = h3Mux

	tcpMux := http.NewServeMux()
	tcpMux.HandleFunc(cfg.WebSocketPath, func(w http.ResponseWriter, r *http.Request) {
		cl, err := verifyAuthHeaders(r.Header, cfg.WebSocketPath, clients, replay, time.Now())
		if err != nil {
			genericNotFound(w)
			return
		}
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			CompressionMode: websocket.CompressionDisabled,
		})
		if err != nil {
			return
		}
		conn.SetReadLimit(1 << 20)
		go servePeer(tun, serverIP, cl, &wsCarrier{conn: conn}, registry, cfg.MTU)
	})
	tcpMux.HandleFunc("/", landingHandler)
	fallbackListen := fallbackTCPListenAddr(cfg.Listen)
	tcpServer := &http.Server{
		Addr:              fallbackListen,
		Handler:           tcpMux,
		TLSConfig:         baseTLS.Clone(),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       75 * time.Second,
	}

	errCh := make(chan error, 2)
	go func() {
		log.Printf("dragon-shield: HTTP/3 WebTransport listening on %s/udp", cfg.Listen)
		errCh <- wtServer.ListenAndServe()
	}()
	go func() {
		log.Printf("dragon-shield: HTTPS/WebSocket fallback listening on %s/tcp", fallbackListen)
		errCh <- tcpServer.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey)
	}()
	return <-errCh
}

func landingHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=300")
	_, _ = w.Write([]byte("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Service</title></head><body><h1>Service online</h1></body></html>"))
}

func serverTunReader(tun *tunDevice, serverIP net.IP, allowed map[string]struct{}, registry *peerRegistry, mtu int) {
	buf := make([]byte, mtu+256)
	for {
		n, err := tun.Read(buf)
		if err != nil {
			log.Printf("dragon-shield: TUN read error: %v", err)
			time.Sleep(time.Second)
			continue
		}
		pkt := append([]byte(nil), buf[:n]...)
		src, dst, ok := ipv4Endpoints(pkt)
		if !ok || !ipEqual(src, serverIP) {
			continue
		}
		if _, ok := allowed[dst.String()]; !ok {
			continue
		}
		p := registry.getByIP(dst)
		if p == nil {
			continue
		}
		frame, err := encodePacket(pkt)
		if err != nil {
			continue
		}
		select {
		case p.send <- frame:
		default:
			p.drops.Add(1)
		}
	}
}

func servePeer(tun *tunDevice, serverIP net.IP, cl ServerClient, c carrier, registry *peerRegistry, mtu int) {
	ctx, cancel := context.WithCancel(context.Background())
	p := &peer{id: cl.ID, ip: net.ParseIP(cl.IP), carrier: c, send: make(chan []byte, 256), cancel: cancel}
	p.lastSeen.Store(time.Now().Unix())
	registry.replace(p)
	log.Printf("dragon-shield: client %s connected via %s", cl.ID, c.Kind())
	defer func() {
		p.closed.Store(true)
		cancel()
		registry.remove(p)
		_ = c.Close()
		log.Printf("dragon-shield: client %s disconnected via %s drops=%d", cl.ID, c.Kind(), p.drops.Load())
	}()

	errCh := make(chan error, 2)
	go func() { errCh <- peerWriter(ctx, c, p.send) }()
	go func() { errCh <- peerReader(ctx, tun, c, p.ip, serverIP, mtu, &p.lastSeen) }()
	<-errCh
}

func peerWriter(ctx context.Context, c carrier, send <-chan []byte) error {
	keepalive := time.NewTicker(20 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case b := <-send:
			wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := c.Send(wctx, b)
			cancel()
			if err != nil {
				return err
			}
		case <-keepalive.C:
			wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := c.Send(wctx, encodeKeepalive())
			cancel()
			if err != nil {
				return err
			}
		}
	}
}

func peerReader(ctx context.Context, tun *tunDevice, c carrier, clientIP, serverIP net.IP, mtu int, lastSeen *atomic.Int64) error {
	for {
		b, err := c.Recv(ctx)
		if err != nil {
			return err
		}
		pkt, keepalive, err := decodeFrame(b)
		if err != nil || keepalive {
			continue
		}
		if len(pkt) > mtu+64 {
			continue
		}
		src, dst, ok := ipv4Endpoints(pkt)
		if !ok || !ipEqual(src, clientIP) || !ipEqual(dst, serverIP) {
			continue
		}
		lastSeen.Store(time.Now().Unix())
		if err := tun.WritePacket(pkt); err != nil {
			return err
		}
	}
}

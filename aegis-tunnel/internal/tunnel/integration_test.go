package tunnel

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

func freeAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a := l.Addr().String()
	_ = l.Close()
	return a
}

func startEchoAt(t *testing.T, addr string) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, e := ln.Accept()
			if e != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_, _ = io.Copy(c, c)
			}(c)
		}
	}()
	return ln
}

func waitPort(t *testing.T, addr string, wantUp bool, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", addr, 120*time.Millisecond)
		up := err == nil
		if c != nil {
			_ = c.Close()
		}
		if up == wantUp {
			return
		}
		time.Sleep(60 * time.Millisecond)
	}
	t.Fatalf("port %s state did not become up=%v", addr, wantUp)
}

func waitSessions(t *testing.T, s *Server, n int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		s.sessionsMu.RLock()
		got := len(s.sessions)
		s.sessionsMu.RUnlock()
		if got >= n {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("sessions did not reach %d", n)
}

func roundTrip(addr string, payload []byte) error {
	conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = conn.Write(payload); err != nil {
		return err
	}
	got := make([]byte, len(payload))
	if _, err = io.ReadFull(conn, got); err != nil {
		return err
	}
	if !bytes.Equal(got, payload) {
		return io.ErrUnexpectedEOF
	}
	return nil
}

func basePair(t *testing.T, pool int, healthTarget, readiness string) (*Server, *Client, string, context.CancelFunc, context.CancelFunc, net.Listener) {
	t.Helper()
	wsAddr := freeAddr(t)
	localAddr := freeAddr(t)
	echoAddr := freeAddr(t)
	echoLn := startEchoAt(t, echoAddr)
	token := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	path := "/api/socket/0123456789abcdef0123456789abcdef"
	s := NewServer(ServerConfig{
		Bind:             wsAddr,
		Token:            token,
		PathPrefix:       path,
		KeepAliveSeconds: 2,
		ReadinessListen:  readiness,
		Listeners:        []ListenerConfig{{Listen: localAddr, TargetID: 1}},
	})
	c := NewClient(ClientConfig{
		RemoteAddr:        wsAddr,
		Scheme:            "ws",
		Token:             token,
		PathPrefix:        path,
		Origin:            "http://localhost",
		Pool:              pool,
		DialTimeoutSec:    1,
		KeepAliveSeconds:  2,
		HealthTarget:      healthTarget,
		HealthIntervalSec: 1,
		Targets:           []TargetConfig{{ID: 1, Address: echoAddr}},
	})
	sctx, scancel := context.WithCancel(context.Background())
	cctx, ccancel := context.WithCancel(context.Background())
	go func() { _ = s.Run(sctx) }()
	time.Sleep(100 * time.Millisecond)
	go func() { _ = c.Run(cctx) }()
	return s, c, localAddr, scancel, ccancel, echoLn
}

func TestPlainWebSocketTunnelParallel(t *testing.T) {
	_, _, localAddr, scancel, ccancel, echoLn := basePair(t, 4, "", "")
	defer scancel()
	defer ccancel()
	defer echoLn.Close()
	time.Sleep(350 * time.Millisecond)

	payload := bytes.Repeat([]byte("aegis-transport-"), 8192)
	var wg sync.WaitGroup
	errs := make(chan error, 32)
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := roundTrip(localAddr, payload); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
}

func TestReadinessTracksCarrierLifecycle(t *testing.T) {
	readyAddr := freeAddr(t)
	_, _, _, scancel, ccancel, echoLn := basePair(t, 2, "", readyAddr)
	defer scancel()
	defer echoLn.Close()
	waitPort(t, readyAddr, true, 3*time.Second)
	ccancel()
	waitPort(t, readyAddr, false, 3*time.Second)
}

func TestBadTokenNeverBecomesReady(t *testing.T) {
	wsAddr := freeAddr(t)
	readyAddr := freeAddr(t)
	localAddr := freeAddr(t)
	echoLn := startEchoAt(t, freeAddr(t))
	defer echoLn.Close()
	path := "/api/socket/0123456789abcdef0123456789abcdef"
	s := NewServer(ServerConfig{Bind: wsAddr, Token: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", PathPrefix: path, ReadinessListen: readyAddr, Listeners: []ListenerConfig{{Listen: localAddr, TargetID: 1}}})
	c := NewClient(ClientConfig{RemoteAddr: wsAddr, Scheme: "ws", Token: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", PathPrefix: path, Pool: 1, DialTimeoutSec: 1, Targets: []TargetConfig{{ID: 1, Address: echoLn.Addr().String()}}})
	sctx, scancel := context.WithCancel(context.Background())
	defer scancel()
	cctx, ccancel := context.WithCancel(context.Background())
	defer ccancel()
	go func() { _ = s.Run(sctx) }()
	time.Sleep(100 * time.Millisecond)
	go func() { _ = c.Run(cctx) }()
	time.Sleep(1200 * time.Millisecond)
	cconn, err := net.DialTimeout("tcp", readyAddr, 150*time.Millisecond)
	if cconn != nil {
		_ = cconn.Close()
	}
	if err == nil {
		t.Fatal("readiness unexpectedly up with bad token")
	}
}

func TestHealthTargetLossDropsReadinessAndRecovers(t *testing.T) {
	wsAddr := freeAddr(t)
	localAddr := freeAddr(t)
	readyAddr := freeAddr(t)
	echoAddr := freeAddr(t)
	echoLn := startEchoAt(t, echoAddr)
	defer func() { _ = echoLn.Close() }()
	token := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	path := "/api/socket/0123456789abcdef0123456789abcdef"
	s := NewServer(ServerConfig{Bind: wsAddr, Token: token, PathPrefix: path, KeepAliveSeconds: 2, ReadinessListen: readyAddr, Listeners: []ListenerConfig{{Listen: localAddr, TargetID: 1}}})
	c := NewClient(ClientConfig{RemoteAddr: wsAddr, Scheme: "ws", Token: token, PathPrefix: path, Pool: 2, DialTimeoutSec: 1, KeepAliveSeconds: 2, HealthTarget: echoAddr, HealthIntervalSec: 1, Targets: []TargetConfig{{ID: 1, Address: echoAddr}}})
	sctx, scancel := context.WithCancel(context.Background())
	defer scancel()
	cctx, ccancel := context.WithCancel(context.Background())
	defer ccancel()
	go func() { _ = s.Run(sctx) }()
	time.Sleep(100 * time.Millisecond)
	go func() { _ = c.Run(cctx) }()

	waitPort(t, readyAddr, true, 4*time.Second)
	if err := roundTrip(localAddr, []byte("before-loss")); err != nil {
		t.Fatal(err)
	}
	_ = echoLn.Close()
	waitPort(t, readyAddr, false, 5*time.Second)

	echoLn = startEchoAt(t, echoAddr)
	waitPort(t, readyAddr, true, 5*time.Second)
	if err := roundTrip(localAddr, []byte("after-recovery")); err != nil {
		t.Fatal(err)
	}
}

func TestCarrierChurnDoesNotPoisonNewStreams(t *testing.T) {
	s, _, localAddr, scancel, ccancel, echoLn := basePair(t, 4, "", "")
	defer scancel()
	defer ccancel()
	defer echoLn.Close()
	waitSessions(t, s, 4, 3*time.Second)

	s.sessionsMu.RLock()
	victim := s.sessions[0]
	s.sessionsMu.RUnlock()
	victim.close()

	deadline := time.Now().Add(4 * time.Second)
	for i := 0; i < 50; i++ {
		var err error
		for attempts := 0; attempts < 4; attempts++ {
			err = roundTrip(localAddr, []byte("carrier-churn"))
			if err == nil {
				break
			}
			time.Sleep(40 * time.Millisecond)
		}
		if err != nil {
			t.Fatalf("stream %d failed after carrier churn: %v", i, err)
		}
		if time.Now().After(deadline) {
			t.Fatal(errors.New("carrier churn test exceeded deadline"))
		}
	}
}

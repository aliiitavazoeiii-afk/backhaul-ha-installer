package tunnel

import (
	"bytes"
	"context"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

func freeAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }
	a := l.Addr().String(); l.Close(); return a
}

func TestPlainWebSocketTunnelParallel(t *testing.T) {
	wsAddr := freeAddr(t); localAddr := freeAddr(t)
	echoLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }
	defer echoLn.Close()
	go func() {
		for {
			c, e := echoLn.Accept(); if e != nil { return }
			go func(c net.Conn) { defer c.Close(); _, _ = io.Copy(c, c) }(c)
		}
	}()

	token := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	path := "/api/socket/0123456789abcdef0123456789abcdef"
	s := NewServer(ServerConfig{Bind: wsAddr, Token: token, PathPrefix: path, KeepAliveSeconds: 2, Listeners: []ListenerConfig{{Listen: localAddr, TargetID: 1}}})
	c := NewClient(ClientConfig{RemoteAddr: wsAddr, Scheme: "ws", Token: token, PathPrefix: path, Origin: "http://localhost", Pool: 3, DialTimeoutSec: 2, KeepAliveSeconds: 2, Targets: []TargetConfig{{ID: 1, Address: echoLn.Addr().String()}}})
	ctx, cancel := context.WithCancel(context.Background()); defer cancel()
	go func() { _ = s.Run(ctx) }(); time.Sleep(100 * time.Millisecond)
	go func() { _ = c.Run(ctx) }(); time.Sleep(350 * time.Millisecond)

	payload := bytes.Repeat([]byte("aegis-transport-"), 8192)
	var wg sync.WaitGroup; errs := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, e := net.DialTimeout("tcp", localAddr, 2*time.Second)
			if e != nil { errs <- e; return }
			defer conn.Close(); _ = conn.SetDeadline(time.Now().Add(5 * time.Second))
			if _, e = conn.Write(payload); e != nil { errs <- e; return }
			got := make([]byte, len(payload))
			if _, e = io.ReadFull(conn, got); e != nil { errs <- e; return }
			if !bytes.Equal(got, payload) { errs <- io.ErrUnexpectedEOF }
		}()
	}
	wg.Wait(); close(errs)
	for e := range errs { if e != nil { t.Fatal(e) } }
}

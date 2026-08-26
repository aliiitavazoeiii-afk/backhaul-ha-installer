package tunnel

import (
	"bufio"
	"io"
	"net"
	"sync"
	"time"
)

type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.r.Read(p) }

var copyBufPool = sync.Pool{New: func() any { return make([]byte, 32*1024) }}

func bridge(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		buf := copyBufPool.Get().([]byte)
		_, _ = io.CopyBuffer(dst, src, buf)
		copyBufPool.Put(buf)
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	_ = a.Close()
	_ = b.Close()
	<-done
}

func tuneTCP(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(30 * time.Second)
	}
}

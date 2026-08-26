package tunnel

import (
	"io"
	"net"
	"testing"
	"time"
)

func TestBridgeTransfersBothWays(t *testing.T) {
	a1, a2 := net.Pipe()
	b1, b2 := net.Pipe()
	go bridge(a2, b2)

	readExact := func(c net.Conn, want string) <-chan error {
		ch := make(chan error, 1)
		go func() {
			buf := make([]byte, len(want))
			_, err := io.ReadFull(c, buf)
			if err == nil && string(buf) != want {
				err = io.ErrUnexpectedEOF
			}
			ch <- err
		}()
		return ch
	}

	wait := func(ch <-chan error) {
		select {
		case err := <-ch:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("timeout")
		}
	}

	r1 := readExact(b1, "hello")
	if _, err := a1.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	wait(r1)

	r2 := readExact(a1, "world")
	if _, err := b1.Write([]byte("world")); err != nil {
		t.Fatal(err)
	}
	wait(r2)

	_ = a1.Close()
	_ = b1.Close()
}

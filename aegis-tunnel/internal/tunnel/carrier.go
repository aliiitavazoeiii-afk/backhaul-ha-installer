package tunnel

import (
	"errors"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-tunnel/internal/proto"
	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-tunnel/internal/ws"
)

const maxStreamsPerCarrier = 4096

type streamState struct {
	id      uint32
	conn    net.Conn
	writeCh chan []byte
	done    chan struct{}
	once    sync.Once
}

func newStreamState(id uint32, conn net.Conn) *streamState {
	s := &streamState{id: id, conn: conn, writeCh: make(chan []byte, 64), done: make(chan struct{})}
	go s.writer()
	return s
}
func (s *streamState) writer() {
	for {
		select {
		case b, ok := <-s.writeCh:
			if !ok {
				return
			}
			_ = s.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if _, err := s.conn.Write(b); err != nil {
				s.close()
				return
			}
			_ = s.conn.SetWriteDeadline(time.Time{})
		case <-s.done:
			return
		}
	}
}
func (s *streamState) enqueue(b []byte) bool {
	cp := append([]byte(nil), b...)
	select {
	case <-s.done:
		return false
	default:
	}
	select {
	case s.writeCh <- cp:
		return true
	case <-s.done:
		return false
	default:
		return false
	}
}
func (s *streamState) close() {
	s.once.Do(func() { close(s.done); _ = s.conn.Close() })
}

type carrier struct {
	id        uint64
	w         *ws.Conn
	streamsMu sync.RWMutex
	streams   map[uint32]*streamState
	closed    chan struct{}
	closeOnce sync.Once
	lastSeen  atomic.Int64
}

func newCarrier(id uint64, w *ws.Conn) *carrier {
	c := &carrier{id: id, w: w, streams: make(map[uint32]*streamState), closed: make(chan struct{})}
	c.touch()
	return c
}
func (c *carrier) touch() { c.lastSeen.Store(time.Now().UnixNano()) }
func (c *carrier) send(f proto.Frame) error {
	b, err := proto.Encode(f)
	if err != nil {
		return err
	}
	return c.w.WriteBinary(b)
}
func (c *carrier) addStream(id uint32, conn net.Conn) (*streamState, error) {
	s := newStreamState(id, conn)
	c.streamsMu.Lock()
	defer c.streamsMu.Unlock()
	if len(c.streams) >= maxStreamsPerCarrier {
		s.close()
		return nil, errors.New("carrier stream limit reached")
	}
	if _, ok := c.streams[id]; ok {
		s.close()
		return nil, errors.New("duplicate stream id")
	}
	c.streams[id] = s
	return s, nil
}
func (c *carrier) getStream(id uint32) *streamState {
	c.streamsMu.RLock()
	defer c.streamsMu.RUnlock()
	return c.streams[id]
}
func (c *carrier) delStream(id uint32) {
	c.streamsMu.Lock()
	s := c.streams[id]
	delete(c.streams, id)
	c.streamsMu.Unlock()
	if s != nil {
		s.close()
	}
}
func (c *carrier) close() {
	c.closeOnce.Do(func() {
		close(c.closed)
		_ = c.w.Close()
		c.streamsMu.Lock()
		ss := make([]*streamState, 0, len(c.streams))
		for _, s := range c.streams {
			ss = append(ss, s)
		}
		c.streams = make(map[uint32]*streamState)
		c.streamsMu.Unlock()
		for _, s := range ss {
			s.close()
		}
	})
}

func copyConnToCarrier(c *carrier, sid uint32, conn net.Conn) {
	buf := make([]byte, proto.MaxData)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			if e := c.send(proto.Frame{Type: proto.TypeData, StreamID: sid, Payload: buf[:n]}); e != nil {
				err = e
			}
		}
		if err != nil {
			if err != io.EOF {
				log.Printf("stream %d read ended: %v", sid, err)
			}
			_ = c.send(proto.Frame{Type: proto.TypeClose, StreamID: sid})
			c.delStream(sid)
			return
		}
	}
}

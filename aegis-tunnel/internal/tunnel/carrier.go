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

const maxStreamsPerCarrier = 1024
const streamQueueDepth = 32
const carrierWriteTimeout = 8 * time.Second

type streamState struct {
	id      uint32
	conn    net.Conn
	writeCh chan []byte
	done    chan struct{}
	once    sync.Once
}

func newStreamState(id uint32, conn net.Conn) *streamState {
	return &streamState{id: id, conn: conn, writeCh: make(chan []byte, streamQueueDepth), done: make(chan struct{})}
}

func (s *streamState) startWriter() { go s.writer() }

func (s *streamState) writer() {
	for {
		select {
		case b := <-s.writeCh:
			_ = s.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if _, err := s.conn.Write(b); err != nil {
				s.stop(true)
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

func (s *streamState) stop(closeConn bool) {
	s.once.Do(func() {
		close(s.done)
		if closeConn {
			_ = s.conn.Close()
		}
	})
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
	if err := c.w.SetWriteDeadline(time.Now().Add(carrierWriteTimeout)); err != nil {
		return err
	}
	err = c.w.WriteBinary(b)
	_ = c.w.SetWriteDeadline(time.Time{})
	return err
}

func (c *carrier) addStream(id uint32, conn net.Conn) (*streamState, error) {
	c.streamsMu.Lock()
	defer c.streamsMu.Unlock()
	if len(c.streams) >= maxStreamsPerCarrier {
		return nil, errors.New("carrier stream limit reached")
	}
	if _, ok := c.streams[id]; ok {
		return nil, errors.New("duplicate stream id")
	}
	s := newStreamState(id, conn)
	c.streams[id] = s
	return s, nil
}

func (c *carrier) getStream(id uint32) *streamState {
	c.streamsMu.RLock()
	defer c.streamsMu.RUnlock()
	return c.streams[id]
}

func (c *carrier) delStream(id uint32) {
	c.removeStream(id, true)
}

func (c *carrier) detachStream(id uint32) {
	c.removeStream(id, false)
}

func (c *carrier) removeStream(id uint32, closeConn bool) {
	c.streamsMu.Lock()
	s := c.streams[id]
	delete(c.streams, id)
	c.streamsMu.Unlock()
	if s != nil {
		s.stop(closeConn)
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
			s.stop(true)
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

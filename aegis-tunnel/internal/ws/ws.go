package ws

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA
)

type Conn struct {
	c          net.Conn
	r          *bufio.Reader
	writeMu    sync.Mutex
	clientSide bool
	MaxPayload int
}

func New(conn net.Conn, reader *bufio.Reader, clientSide bool) *Conn {
	if reader == nil {
		reader = bufio.NewReader(conn)
	}
	return &Conn{c: conn, r: reader, clientSide: clientSide, MaxPayload: 1 << 20}
}

func Accept(w http.ResponseWriter, r *http.Request, token, pathPrefix string) (*Conn, error) {
	if r.Method != http.MethodGet {
		return nil, errors.New("websocket: GET required")
	}
	if !strings.HasPrefix(r.URL.Path, pathPrefix) {
		return nil, errors.New("websocket: path rejected")
	}
	if !headerHasToken(r.Header, "Connection", "upgrade") || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		return nil, errors.New("websocket: upgrade headers missing")
	}
	if r.Header.Get("Sec-WebSocket-Version") != "13" {
		return nil, errors.New("websocket: version 13 required")
	}
	gotAuth := []byte(r.Header.Get("Authorization"))
	wantAuth := []byte("Bearer " + token)
	if len(gotAuth) != len(wantAuth) || !hmac.Equal(gotAuth, wantAuth) {
		return nil, errors.New("websocket: unauthorized")
	}
	key := strings.TrimSpace(r.Header.Get("Sec-WebSocket-Key"))
	if key == "" {
		return nil, errors.New("websocket: key missing")
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		return nil, errors.New("websocket: hijacking unsupported")
	}
	conn, rw, err := hj.Hijack()
	if err != nil {
		return nil, err
	}
	accept := websocketAccept(key)
	if _, err := fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := rw.Flush(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return New(conn, rw.Reader, false), nil
}

func ClientHandshake(conn net.Conn, host, path, token, origin string) (*Conn, error) {
	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(keyBytes)
	if origin == "" {
		origin = "https://" + host
	}
	req := "GET " + path + " HTTP/1.1\r\n" +
		"Host: " + host + "\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: websocket\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"Authorization: Bearer " + token + "\r\n" +
		"Origin: " + origin + "\r\n" +
		"User-Agent: Mozilla/5.0\r\n\r\n"
	if _, err := io.WriteString(conn, req); err != nil {
		return nil, err
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodGet})
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusSwitchingProtocols {
		return nil, fmt.Errorf("websocket: expected 101, got %s", resp.Status)
	}
	if !headerHasToken(resp.Header, "Connection", "upgrade") || !strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") {
		return nil, errors.New("websocket: invalid upgrade response")
	}
	if got, want := strings.TrimSpace(resp.Header.Get("Sec-WebSocket-Accept")), websocketAccept(key); got != want {
		return nil, errors.New("websocket: accept mismatch")
	}
	return New(conn, br, true), nil
}

func websocketAccept(key string) string {
	h := sha1.New()
	_, _ = io.WriteString(h, key+websocketGUID)
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

func headerHasToken(h http.Header, name, token string) bool {
	for _, v := range h.Values(name) {
		for _, p := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(p), token) {
				return true
			}
		}
	}
	return false
}

func (c *Conn) Close() error                       { return c.c.Close() }
func (c *Conn) RemoteAddr() net.Addr               { return c.c.RemoteAddr() }
func (c *Conn) SetReadDeadline(t time.Time) error  { return c.c.SetReadDeadline(t) }
func (c *Conn) SetWriteDeadline(t time.Time) error { return c.c.SetWriteDeadline(t) }
func (c *Conn) SetDeadline(t time.Time) error      { return c.c.SetDeadline(t) }
func (c *Conn) WriteBinary(payload []byte) error   { return c.writeFrame(opBinary, payload) }
func (c *Conn) WritePing(payload []byte) error     { return c.writeFrame(opPing, payload) }
func (c *Conn) WritePong(payload []byte) error     { return c.writeFrame(opPong, payload) }
func (c *Conn) WriteClose() error                  { return c.writeFrame(opClose, nil) }

func (c *Conn) writeFrame(op byte, payload []byte) error {
	if c.MaxPayload > 0 && len(payload) > c.MaxPayload {
		return fmt.Errorf("websocket: payload %d exceeds cap %d", len(payload), c.MaxPayload)
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	var hdr [14]byte
	hdr[0] = 0x80 | op
	n := 2
	maskBit := byte(0)
	if c.clientSide {
		maskBit = 0x80
	}
	l := len(payload)
	switch {
	case l < 126:
		hdr[1] = maskBit | byte(l)
	case l <= 0xffff:
		hdr[1] = maskBit | 126
		binary.BigEndian.PutUint16(hdr[2:4], uint16(l))
		n = 4
	default:
		hdr[1] = maskBit | 127
		binary.BigEndian.PutUint64(hdr[2:10], uint64(l))
		n = 10
	}

	out := payload
	if c.clientSide {
		var mask [4]byte
		if _, err := rand.Read(mask[:]); err != nil {
			return err
		}
		copy(hdr[n:n+4], mask[:])
		n += 4
		out = make([]byte, len(payload))
		for i := range payload {
			out[i] = payload[i] ^ mask[i&3]
		}
	}
	if _, err := c.c.Write(hdr[:n]); err != nil {
		return err
	}
	if len(out) > 0 {
		_, err := c.c.Write(out)
		return err
	}
	return nil
}

func (c *Conn) ReadBinary() ([]byte, error) {
	for {
		op, payload, err := c.readFrame()
		if err != nil {
			return nil, err
		}
		switch op {
		case opBinary:
			return payload, nil
		case opPing:
			if len(payload) <= 125 {
				_ = c.WritePong(payload)
			}
		case opPong:
			continue
		case opClose:
			return nil, io.EOF
		case opText, opContinuation:
			return nil, errors.New("websocket: unsupported frame type")
		default:
			return nil, errors.New("websocket: invalid opcode")
		}
	}
}

func (c *Conn) readFrame() (byte, []byte, error) {
	b0, err := c.r.ReadByte()
	if err != nil {
		return 0, nil, err
	}
	b1, err := c.r.ReadByte()
	if err != nil {
		return 0, nil, err
	}
	if b0&0x80 == 0 {
		return 0, nil, errors.New("websocket: fragmented frames unsupported")
	}
	op := b0 & 0x0f
	masked := b1&0x80 != 0
	if c.clientSide && masked {
		return 0, nil, errors.New("websocket: server frame unexpectedly masked")
	}
	if !c.clientSide && !masked {
		return 0, nil, errors.New("websocket: client frame must be masked")
	}
	var n uint64
	switch b1 & 0x7f {
	case 126:
		var x [2]byte
		if _, err := io.ReadFull(c.r, x[:]); err != nil {
			return 0, nil, err
		}
		n = uint64(binary.BigEndian.Uint16(x[:]))
	case 127:
		var x [8]byte
		if _, err := io.ReadFull(c.r, x[:]); err != nil {
			return 0, nil, err
		}
		n = binary.BigEndian.Uint64(x[:])
		if n > uint64(^uint(0)>>1) {
			return 0, nil, errors.New("websocket: frame too large")
		}
	default:
		n = uint64(b1 & 0x7f)
	}
	if c.MaxPayload > 0 && n > uint64(c.MaxPayload) {
		return 0, nil, fmt.Errorf("websocket: payload %d exceeds cap %d", n, c.MaxPayload)
	}
	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(c.r, mask[:]); err != nil {
			return 0, nil, err
		}
	}
	p := make([]byte, int(n))
	if _, err := io.ReadFull(c.r, p); err != nil {
		return 0, nil, err
	}
	if masked {
		for i := range p {
			p[i] ^= mask[i&3]
		}
	}
	return op, p, nil
}

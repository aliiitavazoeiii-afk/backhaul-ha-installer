package proto

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	Version    = 1
	HeaderSize = 12
	MaxData    = 32 * 1024
)

type Type byte

const (
	TypeHello Type = 1
	TypeOpen  Type = 2
	TypeData  Type = 3
	TypeClose Type = 4
	TypePing  Type = 5
	TypePong  Type = 6
)

type Frame struct {
	Type     Type
	StreamID uint32
	TargetID uint16
	Payload  []byte
}

func Encode(f Frame) ([]byte, error) {
	if len(f.Payload) > MaxData {
		return nil, fmt.Errorf("payload too large: %d", len(f.Payload))
	}
	b := make([]byte, HeaderSize+len(f.Payload))
	b[0] = 'A'
	b[1] = 'G'
	b[2] = Version
	b[3] = byte(f.Type)
	binary.BigEndian.PutUint32(b[4:8], f.StreamID)
	binary.BigEndian.PutUint16(b[8:10], f.TargetID)
	binary.BigEndian.PutUint16(b[10:12], uint16(len(f.Payload)))
	copy(b[12:], f.Payload)
	return b, nil
}

func Decode(b []byte) (Frame, error) {
	if len(b) < HeaderSize {
		return Frame{}, errors.New("short frame")
	}
	if b[0] != 'A' || b[1] != 'G' || b[2] != Version {
		return Frame{}, errors.New("bad frame magic/version")
	}
	n := int(binary.BigEndian.Uint16(b[10:12]))
	if n != len(b)-HeaderSize {
		return Frame{}, errors.New("frame length mismatch")
	}
	if n > MaxData {
		return Frame{}, errors.New("frame payload exceeds cap")
	}
	return Frame{
		Type:     Type(b[3]),
		StreamID: binary.BigEndian.Uint32(b[4:8]),
		TargetID: binary.BigEndian.Uint16(b[8:10]),
		Payload:  append([]byte(nil), b[12:]...),
	}, nil
}

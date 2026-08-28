package shield

import (
	"encoding/binary"
	"errors"
	"net"
)

const (
	frameMagic       = 0xD7
	framePacket      = 0x01
	frameKeepalive   = 0x02
	frameHeaderLen   = 4
	maxEncodedPacket = 2048
)

func encodePacket(pkt []byte) ([]byte, error) {
	if len(pkt) == 0 || len(pkt) > 65535 {
		return nil, errors.New("invalid packet size")
	}
	out := make([]byte, frameHeaderLen+len(pkt))
	out[0] = frameMagic
	out[1] = framePacket
	binary.BigEndian.PutUint16(out[2:4], uint16(len(pkt)))
	copy(out[4:], pkt)
	return out, nil
}

func encodeKeepalive() []byte {
	return []byte{frameMagic, frameKeepalive, 0, 0}
}

func decodeFrame(b []byte) (packet []byte, keepalive bool, err error) {
	if len(b) < frameHeaderLen || b[0] != frameMagic {
		return nil, false, errors.New("bad frame")
	}
	n := int(binary.BigEndian.Uint16(b[2:4]))
	switch b[1] {
	case frameKeepalive:
		if n != 0 || len(b) != frameHeaderLen {
			return nil, false, errors.New("bad keepalive")
		}
		return nil, true, nil
	case framePacket:
		if n == 0 || len(b) != frameHeaderLen+n || len(b) > maxEncodedPacket {
			return nil, false, errors.New("bad packet frame")
		}
		return b[4:], false, nil
	default:
		return nil, false, errors.New("unknown frame type")
	}
}

func ipv4Endpoints(pkt []byte) (src, dst net.IP, ok bool) {
	if len(pkt) < 20 || pkt[0]>>4 != 4 {
		return nil, nil, false
	}
	ihl := int(pkt[0]&0x0f) * 4
	if ihl < 20 || ihl > len(pkt) {
		return nil, nil, false
	}
	total := int(binary.BigEndian.Uint16(pkt[2:4]))
	if total < ihl || total > len(pkt) {
		return nil, nil, false
	}
	return net.IPv4(pkt[12], pkt[13], pkt[14], pkt[15]), net.IPv4(pkt[16], pkt[17], pkt[18], pkt[19]), true
}

func ipEqual(a, b net.IP) bool {
	if a == nil || b == nil {
		return false
	}
	return a.Equal(b)
}

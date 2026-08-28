package shield

import (
	"encoding/binary"
	"net"
	"testing"
)

func testIPv4(src, dst net.IP) []byte {
	b := make([]byte, 20)
	b[0] = 0x45
	binary.BigEndian.PutUint16(b[2:4], uint16(len(b)))
	copy(b[12:16], src.To4())
	copy(b[16:20], dst.To4())
	return b
}

func TestPacketFrameRoundTrip(t *testing.T) {
	pkt := testIPv4(net.ParseIP("10.203.0.2"), net.ParseIP("10.203.0.1"))
	frame, err := encodePacket(pkt)
	if err != nil {
		t.Fatal(err)
	}
	got, keepalive, err := decodeFrame(frame)
	if err != nil {
		t.Fatal(err)
	}
	if keepalive || len(got) != len(pkt) {
		t.Fatalf("unexpected decoded frame")
	}
	src, dst, ok := ipv4Endpoints(got)
	if !ok || !src.Equal(net.ParseIP("10.203.0.2")) || !dst.Equal(net.ParseIP("10.203.0.1")) {
		t.Fatalf("unexpected endpoints src=%v dst=%v", src, dst)
	}
}

func TestKeepalive(t *testing.T) {
	pkt, keepalive, err := decodeFrame(encodeKeepalive())
	if err != nil || !keepalive || pkt != nil {
		t.Fatalf("keepalive decode failed: pkt=%v keepalive=%v err=%v", pkt, keepalive, err)
	}
}

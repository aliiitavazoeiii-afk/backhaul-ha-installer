package shield

import (
	"context"
	"fmt"
	"log"
	"net"
	"strings"
	"sync/atomic"
	"time"
)

func RunClient(cfg ClientConfig) error {
	clientIP, _, _ := net.ParseCIDR(cfg.TunCIDR)
	serverIP := net.ParseIP(cfg.ServerTunIP)
	tun, err := openTun(cfg.TunName)
	if err != nil {
		return err
	}
	defer tun.Close()

	closeVeil, err := startClientVeil(cfg)
	if err != nil {
		return fmt.Errorf("start encrypted UDP veil: %w", err)
	}
	defer closeVeil()

	outbound := make(chan []byte, 256)
	var drops atomic.Uint64
	go clientTunReader(tun, clientIP, serverIP, cfg.MTU, outbound, &drops)

	backoff := 250 * time.Millisecond
	preferWT := true
	for {
		drainPackets(outbound)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		c, err := dialCarrier(ctx, cfg, preferWT)
		cancel()
		if err != nil {
			log.Printf("dragon-shield: connect failed: %v", err)
			time.Sleep(backoff)
			if backoff < 5*time.Second {
				backoff *= 2
				if backoff > 5*time.Second {
					backoff = 5 * time.Second
				}
			}
			continue
		}
		backoff = 250 * time.Millisecond
		preferWT = c.Kind() == "webtransport"
		log.Printf("dragon-shield: connected to %s via %s", transportServer(cfg.Server), c.Kind())
		err = runClientCarrier(tun, c, clientIP, serverIP, cfg.MTU, outbound)
		_ = c.Close()
		log.Printf("dragon-shield: carrier %s ended: %v; tun drops=%d", c.Kind(), err, drops.Load())
		// After a WebTransport failure, allow the auto mode to prefer the TCP fallback once.
		if strings.EqualFold(cfg.Mode, "auto") && c.Kind() == "webtransport" {
			preferWT = false
		} else {
			preferWT = true
		}
		time.Sleep(150 * time.Millisecond)
	}
}

func clientTunReader(tun *tunDevice, clientIP, serverIP net.IP, mtu int, outbound chan<- []byte, drops *atomic.Uint64) {
	buf := make([]byte, mtu+256)
	for {
		n, err := tun.Read(buf)
		if err != nil {
			log.Printf("dragon-shield: client TUN read error: %v", err)
			time.Sleep(time.Second)
			continue
		}
		pkt := append([]byte(nil), buf[:n]...)
		src, dst, ok := ipv4Endpoints(pkt)
		if !ok || !ipEqual(src, clientIP) || !ipEqual(dst, serverIP) {
			continue
		}
		frame, err := encodePacket(pkt)
		if err != nil {
			continue
		}
		select {
		case outbound <- frame:
		default:
			drops.Add(1)
		}
	}
}

func runClientCarrier(tun *tunDevice, c carrier, clientIP, serverIP net.IP, mtu int, outbound <-chan []byte) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	errCh := make(chan error, 2)
	go func() { errCh <- clientWriter(ctx, c, outbound) }()
	go func() { errCh <- clientReader(ctx, tun, c, clientIP, serverIP, mtu) }()
	err := <-errCh
	cancel()
	return err
}

func clientWriter(ctx context.Context, c carrier, outbound <-chan []byte) error {
	keepalive := time.NewTicker(20 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case b := <-outbound:
			wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := c.Send(wctx, b)
			cancel()
			if err != nil {
				return err
			}
		case <-keepalive.C:
			wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := c.Send(wctx, encodeKeepalive())
			cancel()
			if err != nil {
				return err
			}
		}
	}
}

func clientReader(ctx context.Context, tun *tunDevice, c carrier, clientIP, serverIP net.IP, mtu int) error {
	for {
		b, err := c.Recv(ctx)
		if err != nil {
			return err
		}
		pkt, keepalive, err := decodeFrame(b)
		if err != nil || keepalive {
			continue
		}
		if len(pkt) > mtu+64 {
			continue
		}
		src, dst, ok := ipv4Endpoints(pkt)
		if !ok || !ipEqual(src, serverIP) || !ipEqual(dst, clientIP) {
			continue
		}
		if err := tun.WritePacket(pkt); err != nil {
			return fmt.Errorf("write TUN: %w", err)
		}
	}
}

func drainPackets(ch <-chan []byte) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

package shield

import (
	"fmt"
	"os"
	"os/exec"
	"sync"
)

type tunDevice struct {
	f       *os.File
	writeMu sync.Mutex
}

func openTun(name string) (*tunDevice, error) {
	f, err := os.OpenFile("/dev/net/tun", os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("open /dev/net/tun: %w", err)
	}
	// Linux TUNSETIFF: _IOW('T', 202, int). The ifreq layout starts with IFNAMSIZ=16.
	ifreq := make([]byte, 40)
	copy(ifreq[:16], []byte(name))
	const (
		tunSetIFF = 0x400454ca
		iffTun    = 0x0001
		iffNoPI   = 0x1000
	)
	flags := uint16(iffTun | iffNoPI)
	ifreq[16] = byte(flags)
	ifreq[17] = byte(flags >> 8)
	_, _, errno := syscallRawIoctl(f.Fd(), tunSetIFF, uintptrPointer(&ifreq[0]))
	if errno != 0 {
		_ = f.Close()
		return nil, fmt.Errorf("TUNSETIFF %s: %v", name, errno)
	}
	return &tunDevice{f: f}, nil
}

func (t *tunDevice) Read(p []byte) (int, error) { return t.f.Read(p) }

func (t *tunDevice) WritePacket(p []byte) error {
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	_, err := t.f.Write(p)
	return err
}

func (t *tunDevice) Close() error { return t.f.Close() }

func PrepareTun(c CommonTunConfig) error {
	if c.MTU < 576 || c.MTU > 1400 {
		return fmt.Errorf("mtu must be between 576 and 1400")
	}
	_ = exec.Command("ip", "tuntap", "add", "dev", c.TunName, "mode", "tun").Run()
	if out, err := exec.Command("ip", "addr", "flush", "dev", c.TunName).CombinedOutput(); err != nil {
		return fmt.Errorf("ip addr flush: %w: %s", err, out)
	}
	if out, err := exec.Command("ip", "addr", "add", c.TunCIDR, "dev", c.TunName).CombinedOutput(); err != nil {
		return fmt.Errorf("ip addr add: %w: %s", err, out)
	}
	if out, err := exec.Command("ip", "link", "set", "dev", c.TunName, "mtu", fmt.Sprint(c.MTU), "up").CombinedOutput(); err != nil {
		return fmt.Errorf("ip link set: %w: %s", err, out)
	}
	return nil
}

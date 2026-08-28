package shield

import (
	"fmt"
	"io"
	"os/exec"
	"sync"
	"syscall"
)

type tunDevice struct {
	fd      int
	writeMu sync.Mutex
}

func openTun(name string) (*tunDevice, error) {
	// /dev/net/tun is intentionally handled with raw Linux syscalls instead of
	// os.OpenFile. Go's runtime poller treats TUN character devices as
	// non-pollable on Linux and can leave an os.File in a half-configured poll
	// state, which manifests as "read /dev/net/tun: not pollable" after service
	// restarts. A blocking raw fd is exactly what a TUN packet loop needs and
	// avoids involving the runtime netpoller entirely.
	fd, err := syscall.Open("/dev/net/tun", syscall.O_RDWR|syscall.O_CLOEXEC, 0)
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
	_, _, errno := syscallRawIoctl(uintptr(fd), tunSetIFF, uintptrPointer(&ifreq[0]))
	if errno != 0 {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("TUNSETIFF %s: %v", name, errno)
	}
	return &tunDevice{fd: fd}, nil
}

func (t *tunDevice) Read(p []byte) (int, error) {
	n, err := syscall.Read(t.fd, p)
	if err != nil {
		return n, fmt.Errorf("read /dev/net/tun: %w", err)
	}
	return n, nil
}

func (t *tunDevice) WritePacket(p []byte) error {
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	n, err := syscall.Write(t.fd, p)
	if err != nil {
		return fmt.Errorf("write /dev/net/tun: %w", err)
	}
	if n != len(p) {
		return io.ErrShortWrite
	}
	return nil
}

func (t *tunDevice) Close() error { return syscall.Close(t.fd) }

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

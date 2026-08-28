package shield

import (
	"syscall"
	"unsafe"
)

func uintptrPointer(p *byte) uintptr { return uintptr(unsafe.Pointer(p)) }

func syscallRawIoctl(fd uintptr, req uintptr, arg uintptr) (uintptr, uintptr, syscall.Errno) {
	return syscall.Syscall(syscall.SYS_IOCTL, fd, req, arg)
}

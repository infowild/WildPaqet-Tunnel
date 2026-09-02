//go:build linux

package tls

import (
	"syscall"

	"golang.org/x/sys/unix"
)

// tcpNotsentLowat bounds how many bytes the application may queue in a TCP
// send buffer beyond what the kernel has actually put on the wire.
//
// smux multiplexes every user connection onto one TCP stream, so any byte
// already handed to the kernel sits ahead of everything written after it. With
// the default limit (effectively unlimited) one upload can park megabytes there
// and every other stream on that connection waits behind them - which shows up
// as ping and jitter climbing whenever the tunnel is busy. Capping the unsent
// backlog does not cap throughput: the congestion controller still decides how
// much is in flight, and it keeps the window free to be large on a fast path.
//
// 128 KiB is the figure HTTP/2 stacks settle on: enough to keep the link busy
// across a wakeup, small enough that a bulk transfer cannot bury an
// interactive stream.
const tcpNotsentLowat = 128 * 1024

func setNotsentLowat(c syscall.RawConn) error {
	var opErr error
	if err := c.Control(func(fd uintptr) {
		opErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_NOTSENT_LOWAT, tcpNotsentLowat)
	}); err != nil {
		return err
	}
	return opErr
}

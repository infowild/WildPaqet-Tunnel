package buffer

import (
	"context"
	"errors"
	"io"
	"net"
	"time"
)

const (
	// TCPSize matches smux's default MaxFrameSize so one read from a socket
	// becomes exactly one smux frame. The previous 8 KiB buffer turned every
	// 32 KiB of payload into four frames, four HTTP/2 DATA frames, four TLS
	// records and four write syscalls.
	TCPSize = 32 * 1024
	UDPSize = 4 * 1024
	_       = uint(0xFFFF - UDPSize)

	// RelayLinger bounds how long the surviving direction of a relay may keep
	// draining after the other direction has ended.
	RelayLinger = 15 * time.Second
)

func CopyT(dst io.Writer, src io.Reader) error {
	buf := make([]byte, TCPSize)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			w, werr := dst.Write(buf[:n])
			if werr != nil {
				return werr
			}
			if w < n {
				return io.ErrShortWrite
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
	}
}

func CopyU(dst io.Writer, src io.Reader) error {
	buf := make([]byte, UDPSize+1)
	for {
		n, err := src.Read(buf)
		switch {
		case n > UDPSize:
		case n > 0:
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return werr
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
	}
}

type closeWriter interface {
	CloseWrite() error
}

// Relay copies bytes both ways between a local socket and a tunnel stream and
// returns once the exchange is over.
//
// smux streams have no half-close, so the end of one direction cannot be
// signalled to the peer on its own. Tearing the pair down as soon as the first
// direction ends therefore truncated the reply whenever a client finished its
// upload and half-closed its socket. Instead the surviving direction is given a
// bounded grace period to drain, and the local socket's write side is shut down
// when the tunnel stream is the side that ended.
func Relay(ctx context.Context, local net.Conn, remote io.ReadWriter, linger time.Duration) error {
	if linger <= 0 {
		linger = RelayLinger
	}

	type outcome struct {
		fromLocal bool
		err       error
	}
	done := make(chan outcome, 2)
	go func() { done <- outcome{true, CopyT(remote, local)} }()
	go func() { done <- outcome{false, CopyT(local, remote)} }()

	var first error
	select {
	case result := <-done:
		first = result.err
		if !result.fromLocal {
			// The tunnel side is finished. Pass that EOF on to the local peer
			// so it can complete its own send instead of waiting for a reply
			// that will never arrive.
			if cw, ok := local.(closeWriter); ok {
				_ = cw.CloseWrite()
			}
		}
	case <-ctx.Done():
		return ctx.Err()
	}

	timer := time.NewTimer(linger)
	defer timer.Stop()
	select {
	case result := <-done:
		if first == nil {
			first = result.err
		}
	case <-timer.C:
	case <-ctx.Done():
	}
	return first
}

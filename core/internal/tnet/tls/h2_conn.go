package tls

import (
	"io"
	"net"
	"sync"
	"time"
)

// h2StreamConn exposes one full-duplex HTTP/2 request/response body as a
// net.Conn so smux can keep its efficient stream multiplexing unchanged. The
// HTTP/2 layer remains real and standards-compliant on the wire.
type h2StreamConn struct {
	reader  io.ReadCloser
	write   func([]byte) (int, error)
	flush   func() error
	base    net.Conn
	closeFn func()

	writeMu   sync.Mutex
	closeOnce sync.Once
}

func (c *h2StreamConn) Read(p []byte) (int, error) {
	return c.reader.Read(p)
}

func (c *h2StreamConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	n, err := c.write(p)
	if err != nil {
		return n, err
	}
	if c.flush != nil {
		if err := c.flush(); err != nil {
			return n, err
		}
	}
	return n, nil
}

func (c *h2StreamConn) Close() error {
	c.closeOnce.Do(func() {
		if c.closeFn != nil {
			c.closeFn()
		}
		_ = c.reader.Close()
		if c.base != nil {
			_ = c.base.Close()
		}
	})
	return nil
}

func (c *h2StreamConn) LocalAddr() net.Addr  { return c.base.LocalAddr() }
func (c *h2StreamConn) RemoteAddr() net.Addr { return c.base.RemoteAddr() }

func (c *h2StreamConn) SetDeadline(t time.Time) error {
	return c.base.SetDeadline(t)
}

func (c *h2StreamConn) SetReadDeadline(t time.Time) error {
	return c.base.SetReadDeadline(t)
}

func (c *h2StreamConn) SetWriteDeadline(t time.Time) error {
	return c.base.SetWriteDeadline(t)
}

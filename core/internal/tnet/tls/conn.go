package tls

import (
	"fmt"
	"net"
	"time"

	"github.com/xtaci/smux"

	"paqet/internal/protocol"
	"paqet/internal/tnet"
)

type Conn struct {
	conn    net.Conn
	session *smux.Session
}

func newConn(conn net.Conn, session *smux.Session) *Conn {
	return &Conn{conn: conn, session: session}
}

func (c *Conn) OpenStrm() (tnet.Strm, error) {
	stream, err := c.session.OpenStream()
	if err != nil {
		return nil, err
	}
	return &Strm{Stream: stream}, nil
}

func (c *Conn) AcceptStrm() (tnet.Strm, error) {
	stream, err := c.session.AcceptStream()
	if err != nil {
		return nil, err
	}
	return &Strm{Stream: stream}, nil
}

func (c *Conn) Ping(wait bool) error {
	stream, err := c.session.OpenStream()
	if err != nil {
		return fmt.Errorf("ping failed: %w", err)
	}
	defer stream.Close()
	if !wait {
		return nil
	}
	p := protocol.Proto{Type: protocol.PPING}
	if err := p.Write(stream); err != nil {
		return fmt.Errorf("stream ping write failed: %w", err)
	}
	if err := p.Read(stream); err != nil {
		return fmt.Errorf("stream ping read failed: %w", err)
	}
	if p.Type != protocol.PPONG {
		return fmt.Errorf("stream pong failed: unexpected type %d", p.Type)
	}
	return nil
}

func (c *Conn) IsClosed() bool {
	return c.session == nil || c.session.IsClosed()
}

func (c *Conn) NumStreams() int {
	if c.session == nil {
		return 0
	}
	return c.session.NumStreams()
}

func (c *Conn) Close() error {
	var result error
	if c.session != nil {
		result = c.session.Close()
	}
	if c.conn != nil {
		if err := c.conn.Close(); err != nil && result == nil {
			result = err
		}
	}
	return result
}

func (c *Conn) LocalAddr() net.Addr                { return c.conn.LocalAddr() }
func (c *Conn) RemoteAddr() net.Addr               { return c.conn.RemoteAddr() }
func (c *Conn) SetDeadline(t time.Time) error      { return c.conn.SetDeadline(t) }
func (c *Conn) SetReadDeadline(t time.Time) error  { return c.conn.SetReadDeadline(t) }
func (c *Conn) SetWriteDeadline(t time.Time) error { return c.conn.SetWriteDeadline(t) }

type Strm struct {
	*smux.Stream
}

func (s *Strm) SID() int { return int(s.ID()) }

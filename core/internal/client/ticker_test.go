package client

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"paqet/internal/conf"
	"paqet/internal/tnet"
)

type reconnectTestConn struct {
	closed  atomic.Bool
	streams atomic.Int32
}

func (c *reconnectTestConn) OpenStrm() (tnet.Strm, error) {
	return nil, errors.New("not implemented")
}
func (c *reconnectTestConn) AcceptStrm() (tnet.Strm, error) {
	return nil, errors.New("not implemented")
}
func (c *reconnectTestConn) Ping(bool) error                 { return nil }
func (c *reconnectTestConn) IsClosed() bool                  { return c.closed.Load() }
func (c *reconnectTestConn) Close() error                    { c.closed.Store(true); return nil }
func (c *reconnectTestConn) LocalAddr() net.Addr             { return nil }
func (c *reconnectTestConn) RemoteAddr() net.Addr            { return nil }
func (c *reconnectTestConn) SetDeadline(time.Time) error     { return nil }
func (c *reconnectTestConn) SetReadDeadline(time.Time) error { return nil }
func (c *reconnectTestConn) SetWriteDeadline(time.Time) error {
	return nil
}
func (c *reconnectTestConn) NumStreams() int { return int(c.streams.Load()) }

func TestMaintainTimedConnRestoresClosedPoolSlot(t *testing.T) {
	closed := &reconnectTestConn{}
	closed.closed.Store(true)
	replacement := &reconnectTestConn{}
	var dials atomic.Int32
	tc := &timedConn{
		conn: closed,
		connect: func(context.Context) (tnet.Conn, error) {
			dials.Add(1)
			return replacement, nil
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go maintainTimedConn(ctx, tc, 5*time.Millisecond)

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		tc.mu.Lock()
		got := tc.conn
		tc.mu.Unlock()
		if got == replacement {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	tc.mu.Lock()
	got := tc.conn
	tc.mu.Unlock()
	if got != replacement {
		t.Fatal("background supervisor did not replace the closed connection")
	}

	time.Sleep(20 * time.Millisecond)
	if got := dials.Load(); got != 1 {
		t.Fatalf("healthy replacement was redialed %d times", got)
	}
}

func TestRotateSwapsBeforeGracefullyDrainingOldConnection(t *testing.T) {
	old := &reconnectTestConn{}
	old.streams.Store(1)
	replacement := &reconnectTestConn{}
	tc := &timedConn{
		cfg: &conf.Conf{Transport: conf.Transport{TLS: &conf.TLS{
			Mode:                "h2",
			MaxConnectionAge:    time.Hour,
			ConnectionAgeJitter: 0,
			DrainTimeout:        5 * time.Second,
		}}},
		conn:   old,
		expire: time.Now().Add(-time.Second),
		connect: func(context.Context) (tnet.Conn, error) {
			return replacement, nil
		},
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := tc.rotate(ctx); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	tc.mu.Lock()
	got := tc.conn
	tc.mu.Unlock()
	if got != replacement {
		t.Fatal("replacement was not installed before draining")
	}
	if old.closed.Load() {
		t.Fatal("old connection closed while it still had an active stream")
	}
	old.streams.Store(0)
	deadline := time.Now().Add(3 * time.Second)
	for !old.closed.Load() && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !old.closed.Load() {
		t.Fatal("drained old connection was not closed")
	}
}

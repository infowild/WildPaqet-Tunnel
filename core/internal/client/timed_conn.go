package client

import (
	"context"
	"fmt"
	"math/rand"
	"net"
	"sync"
	"time"

	"paqet/internal/conf"
	"paqet/internal/flog"
	"paqet/internal/protocol"
	"paqet/internal/tnet"
	"paqet/internal/tnet/kcp"
	tlsnet "paqet/internal/tnet/tls"
)

type timedConn struct {
	cfg       *conf.Conf
	conn      tnet.Conn
	connect   func(context.Context) (tnet.Conn, error)
	expire    time.Time
	addr      string
	preferred int
	endpoints *endpointPool
	mu        sync.Mutex
}

func newTimedConn(ctx context.Context, cfg *conf.Conf, endpoints *endpointPool, preferred int) (*timedConn, error) {
	var err error
	tc := timedConn{cfg: cfg, preferred: preferred, endpoints: endpoints}
	tc.conn, err = tc.openConn(ctx)
	if err != nil {
		return nil, err
	}
	tc.expire = tc.nextExpiry(time.Now())

	return &tc, nil
}

func (tc *timedConn) openConn(ctx context.Context) (tnet.Conn, error) {
	if tc.connect != nil {
		return tc.connect(ctx)
	}
	return tc.createConn(ctx)
}

func (tc *timedConn) ensureConn(ctx context.Context) (tnet.Conn, error) {
	tc.mu.Lock()
	defer tc.mu.Unlock()

	if tc.conn != nil && !tc.conn.IsClosed() {
		return tc.conn, nil
	}
	if tc.conn != nil {
		flog.Infof("connection lost, retrying....")
		_ = tc.conn.Close()
		tc.conn = nil
	}

	conn, err := tc.openConn(ctx)
	if err != nil {
		return nil, err
	}
	tc.conn = conn
	tc.expire = tc.nextExpiry(time.Now())
	return conn, nil
}

func (tc *timedConn) nextExpiry(now time.Time) time.Time {
	if tc.cfg == nil || tc.cfg.Transport.TLS == nil || tc.cfg.Transport.TLS.Mode != "h2" {
		return time.Time{}
	}
	base := tc.cfg.Transport.TLS.MaxConnectionAge
	jitter := tc.cfg.Transport.TLS.ConnectionAgeJitter
	if base <= 0 {
		return time.Time{}
	}
	if jitter > 0 {
		base += time.Duration(rand.Int63n(int64(2*jitter)+1)) - jitter
	}
	return now.Add(base)
}

func (tc *timedConn) rotationDue(now time.Time) bool {
	tc.mu.Lock()
	defer tc.mu.Unlock()
	return tc.conn != nil && !tc.conn.IsClosed() && !tc.expire.IsZero() && !now.Before(tc.expire)
}

func (tc *timedConn) rotate(ctx context.Context) error {
	tc.mu.Lock()
	if tc.conn == nil || tc.conn.IsClosed() || tc.expire.IsZero() || time.Now().Before(tc.expire) {
		tc.mu.Unlock()
		return nil
	}
	old := tc.conn
	replacement, err := tc.openConn(ctx)
	if err != nil {
		// Avoid a synchronized five-second redial storm when several slots reach
		// their age limit during the same upstream outage.
		tc.expire = time.Now().Add(time.Minute + time.Duration(rand.Int63n(int64(time.Minute))))
		tc.mu.Unlock()
		return err
	}
	tc.conn = replacement
	tc.expire = tc.nextExpiry(time.Now())
	drainTimeout := tc.cfg.Transport.TLS.DrainTimeout
	tc.mu.Unlock()

	go drainAndClose(ctx, old, drainTimeout)
	return nil
}

type streamCountConn interface {
	NumStreams() int
}

func drainAndClose(ctx context.Context, conn tnet.Conn, timeout time.Duration) {
	if timeout <= 0 {
		_ = conn.Close()
		return
	}
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	// A short grace period covers a caller that obtained the old pool slot just
	// before the atomic swap but has not opened its smux stream yet.
	grace := time.NewTimer(time.Second)
	defer grace.Stop()
	select {
	case <-ctx.Done():
		_ = conn.Close()
		return
	case <-deadline.C:
		_ = conn.Close()
		return
	case <-grace.C:
	}

	counter, ok := conn.(streamCountConn)
	if !ok {
		_ = conn.Close()
		return
	}
	for {
		if counter.NumStreams() == 0 {
			_ = conn.Close()
			return
		}
		select {
		case <-ctx.Done():
			_ = conn.Close()
			return
		case <-deadline.C:
			_ = conn.Close()
			return
		case <-ticker.C:
		}
	}
}

func (tc *timedConn) isClosed() bool {
	tc.mu.Lock()
	defer tc.mu.Unlock()
	return tc.conn == nil || tc.conn.IsClosed()
}

func (tc *timedConn) remoteAddr() string {
	tc.mu.Lock()
	defer tc.mu.Unlock()
	return tc.addr
}

func (tc *timedConn) createConn(ctx context.Context) (tnet.Conn, error) {
	if tc.cfg.Transport.Protocol == "tls" {
		return tc.createTLSConn(ctx)
	}

	addrs := tc.cfg.Server.Addrs
	if len(addrs) == 0 && tc.cfg.Server.Addr != nil {
		addrs = []*net.UDPAddr{tc.cfg.Server.Addr}
	}

	var lastErr error
	for _, addr := range addrs {
		conn, err := kcp.Dial(addr, tc.cfg.Transport.KCP, tc.cfg.Network)
		if err != nil {
			lastErr = err
			flog.Warnf("failed to dial %s: %v", addr, err)
			continue
		}
		err = tc.sendTCPF(conn)
		if err != nil {
			conn.Close()
			lastErr = err
			flog.Warnf("failed TCPF handshake with %s: %v", addr, err)
			continue
		}
		tc.addr = addr.String()
		flog.Infof("connected to %s", tc.addr)
		return conn, nil
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("no server addresses configured")
	}
	return nil, lastErr
}

func (tc *timedConn) createTLSConn(ctx context.Context) (tnet.Conn, error) {
	addrs := tc.cfg.Server.Endpoints
	if len(addrs) == 0 {
		return nil, fmt.Errorf("no TLS server endpoints configured")
	}
	if tc.endpoints == nil {
		return nil, fmt.Errorf("TLS endpoint pool is not initialized")
	}
	now := time.Now()
	candidates := tc.endpoints.candidates(addrs, tc.preferred, now)
	if len(candidates) == 0 {
		return nil, tc.endpoints.unavailableError(addrs, now)
	}
	var lastErr error
	for _, addr := range candidates {
		conn, err := tlsnet.Dial(ctx, addr, tc.cfg.Transport.TLS)
		if err != nil {
			tc.endpoints.failure(addr, time.Now())
			lastErr = err
			flog.Warnf("failed to dial TLS endpoint %s: %v", addr, err)
			continue
		}
		tc.endpoints.success(addr)
		tc.addr = addr
		flog.Infof("connected to TLS endpoint %s", addr)
		return conn, nil
	}
	return nil, lastErr
}

func (tc *timedConn) sendTCPF(conn tnet.Conn) error {
	strm, err := conn.OpenStrm()
	if err != nil {
		return err
	}
	defer strm.Close()

	p := protocol.Proto{Type: protocol.PTCPF, TCPF: tc.cfg.Network.TCP.RF}
	err = p.Write(strm)
	if err != nil {
		return err
	}
	return nil
}

func (tc *timedConn) close() {
	tc.mu.Lock()
	defer tc.mu.Unlock()
	if tc.conn != nil {
		_ = tc.conn.Close()
		tc.conn = nil
	}
}

package client

import (
	"context"
	"fmt"
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
	tc.expire = time.Now().Add(300 * time.Second)
	return conn, nil
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

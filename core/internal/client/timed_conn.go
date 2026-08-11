package client

import (
	"fmt"
	"net"
	"time"

	"paqet/internal/conf"
	"paqet/internal/flog"
	"paqet/internal/protocol"
	"paqet/internal/tnet"
	"paqet/internal/tnet/kcp"
)

type timedConn struct {
	cfg    *conf.Conf
	conn   tnet.Conn
	expire time.Time
	addr   string
}

func newTimedConn(cfg *conf.Conf) (*timedConn, error) {
	var err error
	tc := timedConn{cfg: cfg}
	tc.conn, err = tc.createConn()
	if err != nil {
		return nil, err
	}

	return &tc, nil
}

func (tc *timedConn) createConn() (tnet.Conn, error) {
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
	if tc.conn != nil {
		tc.conn.Close()
	}
}

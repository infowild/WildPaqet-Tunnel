package tls

import (
	"context"
	stdtls "crypto/tls"
	"fmt"
	"net"
	"time"

	"github.com/xtaci/smux"

	"paqet/internal/conf"
	"paqet/internal/tnet"
)

func Dial(ctx context.Context, addr string, cfg *conf.TLS) (tnet.Conn, error) {
	if cfg.Mode == "h2" {
		return dialH2(ctx, addr, cfg)
	}
	dialer := net.Dialer{Timeout: cfg.ConnectTimeout, KeepAlive: cfg.KeepAlive}
	raw, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("tls: dial %s: %w", addr, err)
	}
	fail := func(err error) (tnet.Conn, error) {
		_ = raw.Close()
		return nil, err
	}

	tlsCfg, err := clientTLSConfig(cfg)
	if err != nil {
		return fail(err)
	}
	tlsConn := stdtls.Client(raw, tlsCfg)
	handshakeCtx, cancel := context.WithTimeout(ctx, cfg.HandshakeTimeout)
	defer cancel()
	if err := tlsConn.HandshakeContext(handshakeCtx); err != nil {
		return fail(fmt.Errorf("tls: handshake with %s: %w", addr, err))
	}
	if tlsConn.ConnectionState().NegotiatedProtocol != cfg.ALPN {
		return fail(fmt.Errorf("tls: peer did not negotiate ALPN %q", cfg.ALPN))
	}
	if err := tlsConn.SetDeadline(time.Now().Add(cfg.HandshakeTimeout)); err != nil {
		return fail(fmt.Errorf("tls: set authentication deadline: %w", err))
	}
	if err := authenticateClient(tlsConn, []byte(cfg.Secret), time.Now()); err != nil {
		return fail(err)
	}
	if err := tlsConn.SetDeadline(time.Time{}); err != nil {
		return fail(fmt.Errorf("tls: clear authentication deadline: %w", err))
	}

	session, err := smux.Client(tlsConn, smuxConfig(cfg))
	if err != nil {
		return fail(fmt.Errorf("tls: create smux client: %w", err))
	}
	return newConn(tlsConn, session), nil
}

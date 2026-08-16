package tls

import (
	"context"
	stdtls "crypto/tls"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/xtaci/smux"

	"paqet/internal/conf"
	"paqet/internal/tnet"
)

type Listener struct {
	listener  net.Listener
	cfg       *conf.TLS
	tlsCfg    *stdtls.Config
	replays   *replayCache
	accepted  chan acceptResult
	closed    chan struct{}
	sem       chan struct{}
	closeOnce sync.Once
	workers   sync.WaitGroup
}

type acceptResult struct {
	conn tnet.Conn
	err  error
}

func Listen(addr string, cfg *conf.TLS) (tnet.Listener, error) {
	tlsCfg, err := serverTLSConfig(cfg)
	if err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("tls: listen on %s: %w", addr, err)
	}
	l := &Listener{
		listener: listener,
		cfg:      cfg,
		tlsCfg:   tlsCfg,
		replays:  newReplayCache(),
		accepted: make(chan acceptResult, 128),
		closed:   make(chan struct{}),
		sem:      make(chan struct{}, 128),
	}
	go l.acceptLoop()
	return l, nil
}

func (l *Listener) Accept() (tnet.Conn, error) {
	select {
	case <-l.closed:
		return nil, net.ErrClosed
	default:
	}
	select {
	case result := <-l.accepted:
		return result.conn, result.err
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *Listener) acceptLoop() {
	for {
		raw, err := l.listener.Accept()
		if err != nil {
			select {
			case <-l.closed:
				return
			default:
			}
			select {
			case <-l.closed:
				return
			case l.accepted <- acceptResult{err: err}:
			}
			continue
		}
		select {
		case l.sem <- struct{}{}:
			l.workers.Add(1)
			go func() {
				defer l.workers.Done()
				defer func() { <-l.sem }()
				conn, err := l.handshake(raw)
				select {
				case l.accepted <- acceptResult{conn: conn, err: err}:
				case <-l.closed:
					if conn != nil {
						_ = conn.Close()
					}
				}
			}()
		default:
			_ = raw.Close()
		}
	}
}

func (l *Listener) handshake(raw net.Conn) (tnet.Conn, error) {
	fail := func(err error) (tnet.Conn, error) {
		_ = raw.Close()
		return nil, err
	}

	tlsConn := stdtls.Server(raw, l.tlsCfg)
	ctx, cancel := context.WithTimeout(context.Background(), l.cfg.HandshakeTimeout)
	defer cancel()
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		return fail(fmt.Errorf("tls: server handshake: %w", err))
	}
	if tlsConn.ConnectionState().NegotiatedProtocol != l.cfg.ALPN {
		return fail(fmt.Errorf("tls: client did not negotiate ALPN %q", l.cfg.ALPN))
	}
	if err := tlsConn.SetDeadline(time.Now().Add(l.cfg.HandshakeTimeout)); err != nil {
		return fail(fmt.Errorf("tls: set authentication deadline: %w", err))
	}
	if err := authenticateServer(tlsConn, []byte(l.cfg.Secret), l.replays, time.Now()); err != nil {
		return fail(err)
	}
	if err := tlsConn.SetDeadline(time.Time{}); err != nil {
		return fail(fmt.Errorf("tls: clear authentication deadline: %w", err))
	}

	session, err := smux.Server(tlsConn, smuxConfig(l.cfg))
	if err != nil {
		return fail(fmt.Errorf("tls: create smux server: %w", err))
	}
	return newConn(tlsConn, session), nil
}

func (l *Listener) Close() error {
	var err error
	l.closeOnce.Do(func() {
		close(l.closed)
		err = l.listener.Close()
		l.workers.Wait()
	})
	return err
}

func (l *Listener) Addr() net.Addr { return l.listener.Addr() }

// TCP flag filters only apply to the legacy pcap transport.
func (l *Listener) SetClientTCPF(net.Addr, []conf.TCPF) {}
func (l *Listener) DeleteClientTCPF(net.Addr)           {}

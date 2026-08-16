package server

import (
	"context"
	"fmt"

	"paqet/internal/conf"
	"paqet/internal/flog"
	"paqet/internal/tnet"
	"paqet/internal/tnet/kcp"
	tlsnet "paqet/internal/tnet/tls"
)

type Server struct {
	cfg      *conf.Conf
	listener tnet.Listener
}

func New(cfg *conf.Conf) (*Server, error) {
	s := &Server{cfg: cfg}
	return s, nil
}

func (s *Server) Start(ctx context.Context) error {
	var listener tnet.Listener
	var err error
	switch s.cfg.Transport.Protocol {
	case "kcp":
		listener, err = kcp.Listen(s.cfg.Transport.KCP, s.cfg.Network)
	case "tls":
		if len(s.cfg.Listen.Endpoints) == 0 {
			return fmt.Errorf("no TLS listen endpoint configured")
		}
		listener, err = tlsnet.Listen(s.cfg.Listen.Endpoints[0], s.cfg.Transport.TLS)
	default:
		return fmt.Errorf("unsupported transport protocol %q", s.cfg.Transport.Protocol)
	}
	if err != nil {
		return fmt.Errorf("could not start %s listener: %w", s.cfg.Transport.Protocol, err)
	}
	s.listener = listener
	flog.Infof("Server started - %s listening on %s", s.cfg.Transport.Protocol, listener.Addr())

	go s.listen(ctx, listener)
	context.AfterFunc(ctx, func() { listener.Close() })

	return nil
}

func (s *Server) listen(ctx context.Context, listener tnet.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return
			default:
				continue
			}
		}
		flog.Infof("accepted new connection from %s (local: %s)", conn.RemoteAddr(), conn.LocalAddr())

		go func() {
			defer conn.Close()
			defer s.listener.DeleteClientTCPF(conn.RemoteAddr())
			s.handleConn(ctx, conn)
		}()
	}
}

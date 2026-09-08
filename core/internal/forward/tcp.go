package forward

import (
	"context"
	"net"

	"paqet/internal/flog"
	"paqet/internal/pkg/buffer"
)

func (f *Forward) serveTCP(ctx context.Context, listener net.Listener) {
	flog.Infof("TCP forwarder listening on %s -> %s", f.listenAddr, f.targetAddr)

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

		select {
		case f.pending <- struct{}{}:
		default:
			_ = conn.Close()
			continue
		}
		go func() {
			defer conn.Close()
			f.handleTCPConn(ctx, conn)
		}()
	}
}

func (f *Forward) handleTCPConn(ctx context.Context, conn net.Conn) {
	setupCtx, cancel := context.WithTimeout(ctx, f.connectTimeout)
	stopClose := context.AfterFunc(setupCtx, func() { _ = conn.Close() })
	strm, err := f.dialTCP(setupCtx, f.targetAddr)
	stopped := stopClose()
	setupErr := setupCtx.Err()
	cancel()
	<-f.pending
	if err == nil && (!stopped || setupErr != nil) {
		_ = strm.Close()
		return
	}
	if err != nil {
		flog.Errorf("failed to establish stream for %s -> %s: %v", conn.RemoteAddr(), f.targetAddr, err)
		return
	}
	defer strm.Close()
	flog.Infof("accepted TCP connection %s -> %s", conn.RemoteAddr(), f.targetAddr)

	if err := buffer.Relay(ctx, conn, strm, buffer.RelayLinger); err != nil {
		flog.Errorf("TCP stream %d failed for %s -> %s: %v", strm.SID(), conn.RemoteAddr(), f.targetAddr, err)
	}
}

package tls

import (
	"context"
	stdtls "crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/xtaci/smux"
	"golang.org/x/net/http2"

	"paqet/internal/conf"
	"paqet/internal/tnet"
)

type h2ConnContextKey struct{}

type h2Listener struct {
	listener net.Listener
	cfg      *conf.TLS
	replays  *replayCache
	accepted chan acceptResult
	closed   chan struct{}
	decoy    http.Handler
	server   *http.Server

	closeOnce sync.Once
}

func listenH2(addr string, cfg *conf.TLS) (tnet.Listener, error) {
	tlsCfg, err := serverTLSConfig(cfg)
	if err != nil {
		return nil, err
	}
	tlsCfg = tlsCfg.Clone()
	tlsCfg.NextProtos = []string{"h2", "http/1.1"}

	raw, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("h2: listen on %s: %w", addr, err)
	}
	l := &h2Listener{
		listener: raw,
		cfg:      cfg,
		replays:  newReplayCache(),
		accepted: make(chan acceptResult, 128),
		closed:   make(chan struct{}),
		decoy:    newDecoyHandler(cfg.DecoyURL),
	}
	l.server = &http.Server{
		Handler:           http.HandlerFunc(l.routeHTTP),
		TLSConfig:         tlsCfg,
		ReadHeaderTimeout: cfg.HandshakeTimeout,
		IdleTimeout:       2 * cfg.KeepAliveTimeout,
		MaxHeaderBytes:    32 * 1024,
		ErrorLog:          log.New(io.Discard, "", 0),
		ConnContext: func(ctx context.Context, conn net.Conn) context.Context {
			return context.WithValue(ctx, h2ConnContextKey{}, conn)
		},
	}
	uploadWindow := h2UploadWindow(cfg.Smuxbuf)
	if err := http2.ConfigureServer(l.server, &http2.Server{
		MaxConcurrentStreams: 16,
		IdleTimeout:          2 * cfg.KeepAliveTimeout,
		// Go's HTTP/2 server defaults both receive windows to 1 MiB, while its
		// transport defaults the opposite direction to 1 GiB connection /
		// 4 MiB stream. Left alone that caps client->server throughput at a
		// quarter of server->client throughput on the same path, because a
		// window bounds in-flight bytes to window/RTT. Both directions now get
		// the same budget as the smux session buffer.
		MaxUploadBufferPerConnection: uploadWindow,
		MaxUploadBufferPerStream:     uploadWindow,
	}); err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("h2: configure server: %w", err)
	}

	tlsListener := stdtls.NewListener(raw, tlsCfg)
	go func() {
		err := l.server.Serve(tlsListener)
		if err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, net.ErrClosed) {
			select {
			case l.accepted <- acceptResult{err: fmt.Errorf("h2: serve: %w", err)}:
			case <-l.closed:
			}
		}
	}()
	return l, nil
}

func (l *h2Listener) routeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		l.handleCover(w, r)
		return
	}
	l.serveDecoy(w, r)
}

func (l *h2Listener) handleCover(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodConnect {
		l.serveDecoy(w, r)
		return
	}
	token := bearerToken(r.Header.Get("Proxy-Authorization"))
	if err := verifyCoverToken(token, []byte(l.cfg.Secret), l.cfg.CoverPath, l.replays, time.Now()); err != nil {
		l.serveDecoy(w, r)
		return
	}
	base, ok := r.Context().Value(h2ConnContextKey{}).(net.Conn)
	if !ok || base == nil || r.ProtoMajor != 2 {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	controller := http.NewResponseController(w)
	if err := controller.Flush(); err != nil {
		return
	}

	stream := &h2StreamConn{
		reader: r.Body,
		write:  w.Write,
		flush:  controller.Flush,
		base:   base,
		closeFn: func() {
			_ = r.Body.Close()
		},
	}
	session, err := smux.Server(stream, smuxConfig(l.cfg))
	if err != nil {
		_ = stream.Close()
		return
	}
	conn := newConn(stream, session)
	select {
	case l.accepted <- acceptResult{conn: conn}:
	case <-r.Context().Done():
		_ = conn.Close()
		return
	case <-l.closed:
		_ = conn.Close()
		return
	}

	select {
	case <-session.CloseChan():
	case <-r.Context().Done():
		_ = conn.Close()
	case <-l.closed:
		_ = conn.Close()
	}
}

func (l *h2Listener) serveDecoy(w http.ResponseWriter, r *http.Request) {
	r.Header.Del("Authorization")
	r.Header.Del("Proxy-Authorization")
	if r.Method == http.MethodConnect {
		http.NotFound(w, r)
		return
	}
	l.decoy.ServeHTTP(w, r)
}

func (l *h2Listener) Accept() (tnet.Conn, error) {
	select {
	case result := <-l.accepted:
		return result.conn, result.err
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *h2Listener) Close() error {
	var err error
	l.closeOnce.Do(func() {
		close(l.closed)
		err = l.server.Close()
		if closeErr := l.listener.Close(); err == nil && !errors.Is(closeErr, net.ErrClosed) {
			err = closeErr
		}
	})
	return err
}

func (l *h2Listener) Addr() net.Addr                      { return l.listener.Addr() }
func (l *h2Listener) SetClientTCPF(net.Addr, []conf.TCPF) {}
func (l *h2Listener) DeleteClientTCPF(net.Addr)           {}

func newDecoyHandler(rawURL string) http.Handler {
	if rawURL != "" {
		if target, err := url.Parse(rawURL); err == nil {
			proxy := httputil.NewSingleHostReverseProxy(target)
			proxy.ErrorLog = log.New(io.Discard, "", 0)
			proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
				serveBuiltInDecoy(w)
			}
			return proxy
		}
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.NotFound(w, r)
			return
		}
		serveBuiltInDecoy(w)
	})
}

func serveBuiltInDecoy(w http.ResponseWriter) {
	const page = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Welcome</title></head><body><h1>Welcome</h1><p>The service is running.</p></body></html>"
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=300")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, strings.NewReader(page))
}

const (
	// h2MinUploadWindow keeps Go's own default as the floor.
	h2MinUploadWindow = 1 << 20
	// h2MaxUploadWindow bounds what a config file can ask the kernel to buffer
	// per outer connection.
	h2MaxUploadWindow = 64 << 20
)

// h2UploadWindow derives the HTTP/2 client->server receive window from the smux
// session buffer, so neither layer becomes the narrower of the two.
func h2UploadWindow(smuxbuf int) int32 {
	if smuxbuf < h2MinUploadWindow {
		return h2MinUploadWindow
	}
	if smuxbuf > h2MaxUploadWindow {
		return h2MaxUploadWindow
	}
	return int32(smuxbuf)
}

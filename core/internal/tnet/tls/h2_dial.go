package tls

import (
	"context"
	stdtls "crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	utls "github.com/refraction-networking/utls"
	"github.com/xtaci/smux"
	"golang.org/x/net/http2"

	"paqet/internal/conf"
	"paqet/internal/tnet"
)

func dialH2(ctx context.Context, endpoint string, cfg *conf.TLS) (tnet.Conn, error) {
	if err := waitConnectJitter(ctx, cfg.ConnectJitter); err != nil {
		return nil, err
	}

	roots, err := clientRootPool(cfg)
	if err != nil {
		return nil, err
	}

	pipe := newBufferedPipe(h2PipeBuffer)
	reqReader := bufferedPipeReader{p: pipe}
	reqWriter := bufferedPipeWriter{p: pipe}
	reqCtx, cancelRequest := context.WithCancel(ctx)
	var baseMu sync.Mutex
	var base net.Conn

	transport := &http2.Transport{
		AllowHTTP: false,
		DialTLSContext: func(dialCtx context.Context, network, _ string, _ *stdtls.Config) (net.Conn, error) {
			conn, err := dialCoverTLS(dialCtx, network, endpoint, cfg, roots)
			if err != nil {
				return nil, err
			}
			baseMu.Lock()
			base = conn
			baseMu.Unlock()
			return conn, nil
		},
	}

	token, err := createCoverToken([]byte(cfg.Secret), cfg.CoverPath, time.Now())
	if err != nil {
		cancelRequest()
		_ = reqReader.Close()
		_ = reqWriter.Close()
		return nil, err
	}
	requestURL := "https://" + cfg.ServerName + cfg.CoverPath
	req, err := http.NewRequestWithContext(reqCtx, http.MethodConnect, requestURL, reqReader)
	if err != nil {
		cancelRequest()
		_ = reqReader.Close()
		_ = reqWriter.Close()
		return nil, fmt.Errorf("h2: create cover request: %w", err)
	}
	req.Host = cfg.ServerName
	req.Header.Set("Proxy-Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("Cache-Control", "no-cache")
	req.Header.Set("User-Agent", coverUserAgent(cfg.ClientHello))

	handshakeTimer := time.AfterFunc(cfg.HandshakeTimeout, cancelRequest)
	resp, err := transport.RoundTrip(req)
	if !handshakeTimer.Stop() && err == nil {
		err = context.DeadlineExceeded
	}
	if err != nil {
		cancelRequest()
		_ = reqWriter.CloseWithError(err)
		_ = reqReader.CloseWithError(err)
		transport.CloseIdleConnections()
		return nil, fmt.Errorf("h2: cover request to %s: %w", endpoint, err)
	}
	if resp.StatusCode != http.StatusOK || resp.ProtoMajor != 2 {
		cancelRequest()
		_ = resp.Body.Close()
		_ = reqWriter.Close()
		transport.CloseIdleConnections()
		return nil, fmt.Errorf("h2: endpoint returned %s over %s", resp.Status, resp.Proto)
	}

	baseMu.Lock()
	baseConn := base
	baseMu.Unlock()
	if baseConn == nil {
		cancelRequest()
		_ = resp.Body.Close()
		_ = reqWriter.Close()
		transport.CloseIdleConnections()
		return nil, fmt.Errorf("h2: transport did not expose its TLS connection")
	}

	stream := &h2StreamConn{
		reader: resp.Body,
		write:  reqWriter.Write,
		base:   baseConn,
		closeFn: func() {
			cancelRequest()
			_ = reqWriter.Close()
			transport.CloseIdleConnections()
		},
	}
	session, err := smux.Client(stream, smuxConfig(cfg))
	if err != nil {
		_ = stream.Close()
		return nil, fmt.Errorf("h2: create smux client: %w", err)
	}
	return newConn(stream, session), nil
}

func dialCoverTLS(ctx context.Context, network, endpoint string, cfg *conf.TLS, roots *x509.CertPool) (net.Conn, error) {
	dialer := net.Dialer{Timeout: cfg.ConnectTimeout, KeepAlive: cfg.KeepAlive}
	raw, err := dialer.DialContext(ctx, network, endpoint)
	if err != nil {
		return nil, fmt.Errorf("h2: dial %s: %w", endpoint, err)
	}
	fail := func(err error) (net.Conn, error) {
		_ = raw.Close()
		return nil, err
	}

	tlsCfg := &utls.Config{
		ServerName: cfg.ServerName,
		RootCAs:    roots,
		// Offer the normal browser range in ClientHello. The WildPaqet server
		// still enforces TLS 1.3, so the negotiated connection cannot downgrade.
		MinVersion: utls.VersionTLS12,
		MaxVersion: utls.VersionTLS13,
		NextProtos: []string{"h2", "http/1.1"},
	}
	uconn := utls.UClient(raw, tlsCfg, coverClientHello(cfg.ClientHello))
	handshakeCtx, cancel := context.WithTimeout(ctx, cfg.HandshakeTimeout)
	defer cancel()
	if err := uconn.HandshakeContext(handshakeCtx); err != nil {
		return fail(fmt.Errorf("h2: TLS handshake with %s: %w", endpoint, err))
	}
	if uconn.ConnectionState().NegotiatedProtocol != "h2" {
		return fail(fmt.Errorf("h2: peer did not negotiate HTTP/2"))
	}
	return uconn, nil
}

func coverClientHello(name string) utls.ClientHelloID {
	switch name {
	case "firefox":
		return utls.HelloFirefox_Auto
	case "randomized":
		return utls.HelloRandomizedALPN
	default:
		return utls.HelloChrome_Auto
	}
}

func coverUserAgent(name string) string {
	switch name {
	case "firefox":
		return "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
	case "randomized":
		return "Mozilla/5.0"
	default:
		return "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36"
	}
}

func waitConnectJitter(ctx context.Context, maximum time.Duration) error {
	if maximum <= 0 {
		return nil
	}
	delay := jitterDuration(maximum/2, maximum/2)
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func bearerToken(header string) string {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(header, prefix))
}

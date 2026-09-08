package tls

import (
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// An active prober must not be able to tell this endpoint from an ordinary web
// server in one unauthenticated request. Go's http.NotFoundHandler answered
// every path with the literal body "404 page not found" and no Server header,
// which identified the host as a bare Go program.
func TestDecoyDoesNotLeakGoDefaultResponse(t *testing.T) {
	handler := newDecoyHandler("")
	for _, method := range []string{"GET", "HEAD", "POST", "PUT"} {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest(method, "/anything", nil))
		body := w.Body.String()
		if strings.Contains(body, "404 page not found") {
			t.Fatalf("%s: Go's default not-found body reached the wire: %q", method, body)
		}
		if w.Header().Get("Server") == "" {
			t.Fatalf("%s: response carries no Server header", method)
		}
		if !strings.Contains(body, "<html>") {
			t.Fatalf("%s: error page is not HTML: %q", method, body)
		}
	}
}

// A failing decoy backend must render a gateway page, not Go's plain-text error.
func TestDecoyProxyErrorIsNotPlainText(t *testing.T) {
	// Port 0 is never connectable, so the proxy always fails.
	handler := newDecoyHandler("http://127.0.0.1:1")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("GET", "https://public.example/", nil))
	if w.Code != http.StatusBadGateway {
		t.Fatalf("want 502, got %d", w.Code)
	}
	if w.Header().Get("Server") == "" || !strings.Contains(w.Body.String(), "<html>") {
		t.Fatalf("gateway error is not a web-server page: %q", w.Body.String())
	}
}

// Practically every real HTTPS site still answers a TLS 1.2 ClientHello.
// Refusing one separated this endpoint from the web in a single probe.
func TestServerAcceptsTLS12ForCover(t *testing.T) {
	certFile, keyFile := makeTestCertificate(t, "cover.example.test")
	cfg := testTLSConfig("0123456789abcdef0123456789abcdef")
	cfg.Mode, cfg.SmuxVersion = "h2", 2
	cfg.ServerName, cfg.CoverPath = "cover.example.test", "/api/v1/test/events"
	cfg.CertFile, cfg.KeyFile = certFile, keyFile

	listener, err := Listen("127.0.0.1:0", cfg)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	pemBytes, err := os.ReadFile(certFile)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(pemBytes)

	raw, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	conn := tls.Client(raw, &tls.Config{
		RootCAs:    roots,
		ServerName: "cover.example.test",
		MaxVersion: tls.VersionTLS12,
		NextProtos: []string{"h2", "http/1.1"},
	})
	defer conn.Close()
	if err := conn.Handshake(); err != nil {
		t.Fatalf("server refused a TLS 1.2 ClientHello, which no ordinary site does: %v", err)
	}
	if got := conn.ConnectionState().Version; got != tls.VersionTLS12 {
		t.Fatalf("negotiated 0x%04x, want TLS 1.2", got)
	}
}

// The tunnel itself must still refuse to run below TLS 1.3: in 1.2 the server
// certificate travels in the clear. The cover ClientHello offers 1.2 only so it
// stays a browser ClientHello.
func TestCoverDialRejectsTLS12Downgrade(t *testing.T) {
	certFile, keyFile := makeTestCertificate(t, "downgrade.example.test")
	certificate, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		t.Fatal(err)
	}
	// A server that can only do TLS 1.2 stands in for a downgrading middlebox.
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{certificate},
		MinVersion:   tls.VersionTLS12,
		MaxVersion:   tls.VersionTLS12,
		NextProtos:   []string{"h2"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			go func() { _, _ = io.Copy(io.Discard, c); c.Close() }()
		}
	}()

	cfg := testTLSConfig("0123456789abcdef0123456789abcdef")
	cfg.Mode = "h2"
	cfg.ServerName, cfg.SendServerName = "downgrade.example.test", true
	cfg.CoverPath, cfg.ClientHello = "/api/v1/packet/events", "chrome"
	cfg.CAFile = certFile

	_, err = dialCoverTLS(t.Context(), "tcp", listener.Addr().String(), cfg, mustPool(t, certFile))
	if err == nil {
		t.Fatal("cover dial accepted a TLS 1.2 session")
	}
	if !strings.Contains(err.Error(), "want TLS 1.3") {
		t.Fatalf("wrong rejection reason: %v", err)
	}
}

func mustPool(t *testing.T, certFile string) *x509.CertPool {
	t.Helper()
	pemBytes, err := os.ReadFile(certFile)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pemBytes) {
		t.Fatal("no certificate in pool")
	}
	return pool
}

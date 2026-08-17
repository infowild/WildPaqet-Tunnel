package tls

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	stdtls "crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/net/http2"

	"paqet/internal/conf"
)

func TestH2CoverTransportRoundTripAndDecoy(t *testing.T) {
	certFile, keyFile := makeTestCertificate(t, "cover.example.test")
	secret := "0123456789abcdef0123456789abcdef"
	serverCfg := testTLSConfig(secret)
	serverCfg.Mode = "h2"
	serverCfg.ServerName = "cover.example.test"
	serverCfg.CoverPath = "/api/v1/test/events"
	serverCfg.CertFile = certFile
	serverCfg.KeyFile = keyFile
	payload := bytes.Repeat([]byte("wildpaqet-h2-flow-control-"), 320000)

	listener, err := Listen("127.0.0.1:0", serverCfg)
	if err != nil {
		t.Fatalf("listen h2: %v", err)
	}
	defer listener.Close()

	serverErr := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			serverErr <- err
			return
		}
		defer conn.Close()
		stream, err := conn.AcceptStrm()
		if err != nil {
			serverErr <- err
			return
		}
		defer stream.Close()
		_, err = io.CopyN(stream, stream, int64(len(payload)))
		serverErr <- err
	}()

	clientCfg := testTLSConfig(secret)
	clientCfg.Mode = "h2"
	clientCfg.ServerName = "cover.example.test"
	clientCfg.SendServerName = true
	clientCfg.CoverPath = serverCfg.CoverPath
	clientCfg.ClientHello = "chrome"
	clientCfg.CAFile = certFile
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := Dial(ctx, listener.Addr().String(), clientCfg)
	if err != nil {
		t.Fatalf("dial h2: %v", err)
	}
	defer conn.Close()
	stream, err := conn.OpenStrm()
	if err != nil {
		t.Fatalf("open h2 stream: %v", err)
	}
	defer stream.Close()
	writeErr := make(chan error, 1)
	go func() { writeErr <- writeAll(stream, payload) }()
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(stream, got); err != nil {
		t.Fatalf("read h2 stream: %v", err)
	}
	if err := <-writeErr; err != nil {
		t.Fatalf("write h2 stream: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("large h2 echo payload changed in transit")
	}
	if err := <-serverErr; err != nil {
		t.Fatalf("h2 server: %v", err)
	}

	roots := x509.NewCertPool()
	pemBytes, err := os.ReadFile(certFile)
	if err != nil || !roots.AppendCertsFromPEM(pemBytes) {
		t.Fatal("load decoy test CA")
	}
	transport := &http.Transport{TLSClientConfig: &stdtls.Config{
		RootCAs:    roots,
		ServerName: "cover.example.test",
		NextProtos: []string{"h2", "http/1.1"},
	}}
	if err := http2.ConfigureTransport(transport); err != nil {
		t.Fatal(err)
	}
	httpClient := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	req, err := http.NewRequest(http.MethodGet, "https://"+listener.Addr().String()+"/", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		t.Fatalf("decoy request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || resp.ProtoMajor != 2 {
		t.Fatalf("decoy = %s over %s, want 200 over h2", resp.Status, resp.Proto)
	}

	h1Client := &http.Client{Transport: &http.Transport{
		TLSClientConfig: &stdtls.Config{
			RootCAs:    roots,
			ServerName: "cover.example.test",
			NextProtos: []string{"http/1.1"},
		},
		ForceAttemptHTTP2: false,
	}, Timeout: 5 * time.Second}
	h1Resp, err := h1Client.Get("https://" + listener.Addr().String() + "/")
	if err != nil {
		t.Fatalf("HTTP/1.1 decoy request: %v", err)
	}
	defer h1Resp.Body.Close()
	if h1Resp.StatusCode != http.StatusOK || h1Resp.ProtoMajor != 1 {
		t.Fatalf("HTTP/1.1 decoy = %s over %s", h1Resp.Status, h1Resp.Proto)
	}
}

func TestDirectTLSTransportRoundTrip(t *testing.T) {
	certFile, keyFile := makeTestCertificate(t, "wildpaqet-v3")
	secret := "0123456789abcdef0123456789abcdef"
	serverCfg := testTLSConfig(secret)
	serverCfg.CertFile = certFile
	serverCfg.KeyFile = keyFile

	listener, err := Listen("127.0.0.1:0", serverCfg)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	serverErr := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			serverErr <- err
			return
		}
		defer conn.Close()
		stream, err := conn.AcceptStrm()
		if err != nil {
			serverErr <- err
			return
		}
		defer stream.Close()
		_, err = io.CopyN(stream, stream, 4)
		serverErr <- err
	}()

	clientCfg := testTLSConfig(secret)
	clientCfg.CAFile = certFile
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := Dial(ctx, listener.Addr().String(), clientCfg)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	stream, err := conn.OpenStrm()
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	defer stream.Close()
	if _, err := stream.Write([]byte("ping")); err != nil {
		t.Fatalf("write: %v", err)
	}
	got := make([]byte, 4)
	if _, err := io.ReadFull(stream, got); err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(got) != "ping" {
		t.Fatalf("echo = %q, want ping", got)
	}
	if err := <-serverErr; err != nil {
		t.Fatalf("server: %v", err)
	}
}

func TestCertificateReloaderPicksUpRenewedFiles(t *testing.T) {
	certFile, keyFile := makeTestCertificate(t, "renew.example.test")
	reloader, err := newCertificateReloader(certFile, keyFile)
	if err != nil {
		t.Fatal(err)
	}
	first, err := reloader.load()
	if err != nil {
		t.Fatal(err)
	}
	newCertFile, newKeyFile := makeTestCertificate(t, "renew.example.test")
	newCert, err := os.ReadFile(newCertFile)
	if err != nil {
		t.Fatal(err)
	}
	newKey, err := os.ReadFile(newKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(certFile, newCert, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, newKey, 0o600); err != nil {
		t.Fatal(err)
	}
	changed := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(certFile, changed, changed); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(keyFile, changed, changed); err != nil {
		t.Fatal(err)
	}
	second, err := reloader.load()
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(first.Certificate[0], second.Certificate[0]) {
		t.Fatal("renewed certificate was not reloaded")
	}
}

func testTLSConfig(secret string) *conf.TLS {
	return &conf.TLS{
		Secret:           secret,
		ALPN:             "h2",
		ConnectTimeout:   2 * time.Second,
		HandshakeTimeout: 2 * time.Second,
		KeepAlive:        15 * time.Second,
		KeepAliveTimeout: 60 * time.Second,
		Smuxbuf:          1024 * 1024,
		Streambuf:        256 * 1024,
	}
}

func makeTestCertificate(t *testing.T, identity string) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: identity},
		DNSNames:              []string{identity},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	certFile := filepath.Join(dir, "server.crt")
	keyFile := filepath.Join(dir, "server.key")
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	return certFile, keyFile
}

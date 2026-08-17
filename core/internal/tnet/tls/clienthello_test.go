package tls

import (
	"bytes"
	stdtls "crypto/tls"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"

	utls "github.com/refraction-networking/utls"

	"paqet/internal/conf"
)

func TestPrivateClientHelloUsesCommonALPNWithoutSNI(t *testing.T) {
	cfg := &conf.TLS{
		ServerName:       "private-tunnel.example",
		SendServerName:   false,
		ALPN:             "h2",
		HandshakeTimeout: time.Second,
	}
	hello := captureClientHello(t, cfg)
	if bytes.Contains(hello, []byte(cfg.ServerName)) {
		t.Fatal("private server name leaked in the visible ClientHello")
	}
	if !bytes.Contains(hello, []byte("h2")) {
		t.Fatal("common h2 ALPN was not offered")
	}
}

func TestPublicClientHelloCanSendSNIExplicitly(t *testing.T) {
	cfg := &conf.TLS{
		ServerName:       "public.example.com",
		SendServerName:   true,
		ALPN:             "h2",
		HandshakeTimeout: time.Second,
	}
	hello := captureClientHello(t, cfg)
	if !bytes.Contains(hello, []byte(cfg.ServerName)) {
		t.Fatal("explicit public SNI was not included in the ClientHello")
	}
}

func TestH2CoverClientHelloExposesOnlyPublicSNIAndALPN(t *testing.T) {
	serverName := "cover.example.test"
	coverPath := "/api/v1/secret/events"
	client, server := net.Pipe()
	uconn := utls.UClient(client, &utls.Config{
		ServerName: serverName,
		MinVersion: utls.VersionTLS12,
		MaxVersion: utls.VersionTLS13,
		NextProtos: []string{"h2", "http/1.1"},
	}, utls.HelloChrome_Auto)
	done := make(chan error, 1)
	go func() { done <- uconn.Handshake() }()

	header := make([]byte, 5)
	if _, err := io.ReadFull(server, header); err != nil {
		t.Fatalf("read cover TLS record header: %v", err)
	}
	payload := make([]byte, int(binary.BigEndian.Uint16(header[3:5])))
	if _, err := io.ReadFull(server, payload); err != nil {
		t.Fatalf("read cover ClientHello: %v", err)
	}
	hello := append(header, payload...)
	_ = server.Close()
	_ = client.Close()
	<-done
	if !bytes.Contains(hello, []byte(serverName)) {
		t.Fatal("HTTP/2 cover ClientHello did not include its public SNI")
	}
	if !bytes.Contains(hello, []byte("h2")) {
		t.Fatal("HTTP/2 cover ClientHello did not offer h2")
	}
	if bytes.Contains(hello, []byte(coverPath)) || bytes.Contains(hello, []byte(authMagic)) {
		t.Fatal("private cover metadata leaked before TLS encryption")
	}
}

func captureClientHello(t *testing.T, cfg *conf.TLS) []byte {
	t.Helper()
	tlsCfg, err := clientTLSConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	client, server := net.Pipe()
	tlsClient := stdtls.Client(client, tlsCfg)
	done := make(chan error, 1)
	go func() { done <- tlsClient.Handshake() }()

	header := make([]byte, 5)
	if _, err := io.ReadFull(server, header); err != nil {
		t.Fatalf("read TLS record header: %v", err)
	}
	payload := make([]byte, int(binary.BigEndian.Uint16(header[3:5])))
	if _, err := io.ReadFull(server, payload); err != nil {
		t.Fatalf("read ClientHello: %v", err)
	}
	_ = server.Close()
	_ = client.Close()
	<-done
	return append(header, payload...)
}

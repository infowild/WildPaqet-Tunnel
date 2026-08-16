package tls

import (
	"bytes"
	stdtls "crypto/tls"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"

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

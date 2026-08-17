package tls

import (
	"bytes"
	"context"
	stdtls "crypto/tls"
	"io"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

type recordingConn struct {
	net.Conn
	mu   sync.Mutex
	read bytes.Buffer
}

func (c *recordingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if n > 0 {
		c.mu.Lock()
		_, _ = c.read.Write(p[:n])
		c.mu.Unlock()
	}
	return n, err
}

func (c *recordingConn) bytesRead() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return bytes.Clone(c.read.Bytes())
}

func TestH2CoverPacketLevelUsesRealPrefaceAndFrames(t *testing.T) {
	certFile, keyFile := makeTestCertificate(t, "packet.example.test")
	certificate, err := stdtls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	recorded := make(chan []byte, 1)
	serverErr := make(chan error, 1)
	var sawConnect atomic.Bool
	go func() {
		raw, err := listener.Accept()
		if err != nil {
			serverErr <- err
			return
		}
		tlsConn := stdtls.Server(raw, &stdtls.Config{
			MinVersion:   stdtls.VersionTLS13,
			Certificates: []stdtls.Certificate{certificate},
			NextProtos:   []string{"h2"},
		})
		if err := tlsConn.Handshake(); err != nil {
			serverErr <- err
			return
		}
		recorder := &recordingConn{Conn: tlsConn}
		h2Server := http2.Server{}
		h2Server.ServeConn(recorder, &http2.ServeConnOpts{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodConnect {
				sawConnect.Store(true)
			}
			w.Header().Set("Content-Type", "application/octet-stream")
			w.WriteHeader(http.StatusOK)
			_ = http.NewResponseController(w).Flush()
			_, _ = io.Copy(io.Discard, r.Body)
		})})
		recorded <- recorder.bytesRead()
		serverErr <- nil
	}()

	secret := "0123456789abcdef0123456789abcdef"
	clientCfg := testTLSConfig(secret)
	clientCfg.Mode = "h2"
	clientCfg.ServerName = "packet.example.test"
	clientCfg.SendServerName = true
	clientCfg.CoverPath = "/api/v1/packet/events"
	clientCfg.ClientHello = "chrome"
	clientCfg.CAFile = certFile
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := Dial(ctx, listener.Addr().String(), clientCfg)
	if err != nil {
		t.Fatalf("dial packet capture server: %v", err)
	}
	stream, err := conn.OpenStrm()
	if err != nil {
		t.Fatalf("open captured stream: %v", err)
	}
	_ = stream.Close()
	_ = conn.Close()

	select {
	case got := <-recorded:
		if !bytes.HasPrefix(got, []byte(http2.ClientPreface)) {
			t.Fatalf("first decrypted application bytes are not the HTTP/2 preface: %x", got[:min(len(got), 32)])
		}
		if len(got) <= len(http2.ClientPreface)+9 {
			t.Fatal("HTTP/2 preface was not followed by a frame")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for packet-level capture")
	}
	if err := <-serverErr; err != nil {
		t.Fatalf("packet capture server: %v", err)
	}
	if !sawConnect.Load() {
		t.Fatal("HTTP/2 carrier did not use the standard CONNECT method")
	}
}

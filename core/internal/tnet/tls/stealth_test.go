package tls

import (
	"bytes"
	"context"
	"crypto/rand"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

func TestStealthRoundTrip(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	srv := testTLSConfig(secret)
	srv.Mode, srv.SmuxVersion = "stealth", 2
	listener, err := Listen("127.0.0.1:0", srv)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				for {
					s, err := c.AcceptStrm()
					if err != nil {
						return
					}
					go func() { io.Copy(s, s); s.Close() }()
				}
			}()
		}
	}()

	cli := testTLSConfig(secret)
	cli.Mode, cli.SmuxVersion = "stealth", 2
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := Dial(ctx, listener.Addr().String(), cli)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	s, err := conn.OpenStrm()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	// Sizes either side of one record, so chunking is exercised.
	payload := make([]byte, 5*stealthMaxChunk+777)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	go func() { s.Write(payload) }()
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(s, got); err != nil {
		t.Fatalf("read back: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("payload changed in transit")
	}
}

// The whole point of the carrier: a peer without the secret gets no reply at
// all, so a scan finds a dead port rather than a service to fingerprint.
func TestStealthPortLooksDeadWithoutTheSecret(t *testing.T) {
	srv := testTLSConfig("0123456789abcdef0123456789abcdef")
	srv.Mode, srv.SmuxVersion = "stealth", 2
	listener, err := Listen("127.0.0.1:0", srv)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			if _, err := listener.Accept(); err != nil {
				return
			}
		}
	}()

	probes := map[string][]byte{
		"random bytes":   {0x00, 0x20, 0xde, 0xad, 0xbe, 0xef, 0x11, 0x22},
		"TLS hello":      {0x16, 0x03, 0x01, 0x00, 0x05, 0x01, 0x00, 0x00, 0x01, 0x00},
		"HTTP request":   []byte("GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
		"nothing at all": nil,
	}
	for name, probe := range probes {
		raw, err := net.Dial("tcp", listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		if len(probe) > 0 {
			if _, err := raw.Write(probe); err != nil {
				raw.Close()
				continue
			}
		}
		_ = raw.SetReadDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 256)
		n, err := raw.Read(buf)
		raw.Close()
		if n > 0 {
			t.Fatalf("%s: server answered %d bytes (%q); the port must stay silent", name, n, buf[:n])
		}
		if err == nil {
			t.Fatalf("%s: read returned no error and no data", name)
		}
	}
}

// A wrong secret must fail closed rather than fall back to anything.
func TestStealthRejectsAWrongSecret(t *testing.T) {
	srv := testTLSConfig("0123456789abcdef0123456789abcdef")
	srv.Mode, srv.SmuxVersion = "stealth", 2
	listener, err := Listen("127.0.0.1:0", srv)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			if _, err := listener.Accept(); err != nil {
				return
			}
		}
	}()

	cli := testTLSConfig("ffffffffffffffffffffffffffffffff")
	cli.Mode, cli.SmuxVersion = "stealth", 2
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := Dial(ctx, listener.Addr().String(), cli); err == nil {
		t.Fatal("a client with the wrong secret completed the handshake")
	}
}

// Nothing recognisable may appear on the wire: no TLS record header, no ALPN,
// no plaintext protocol markers.
func TestStealthWireHasNoProtocolMarkers(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	srv := testTLSConfig(secret)
	srv.Mode, srv.SmuxVersion = "stealth", 2
	listener, err := Listen("127.0.0.1:0", srv)
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
			go func() {
				for {
					s, err := c.AcceptStrm()
					if err != nil {
						return
					}
					go func() { io.Copy(s, s); s.Close() }()
				}
			}()
		}
	}()

	var captured bytes.Buffer
	relay, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		in, err := relay.Accept()
		if err != nil {
			return
		}
		out, err := net.Dial("tcp", listener.Addr().String())
		if err != nil {
			in.Close()
			return
		}
		go io.Copy(in, out)
		io.Copy(io.MultiWriter(out, &captured), in)
	}()

	cli := testTLSConfig(secret)
	cli.Mode, cli.SmuxVersion = "stealth", 2
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := Dial(ctx, relay.Addr().String(), cli)
	if err != nil {
		t.Fatal(err)
	}
	s, err := conn.OpenStrm()
	if err != nil {
		t.Fatal(err)
	}
	s.Write([]byte("wildpaqet"))
	time.Sleep(200 * time.Millisecond)
	s.Close()
	conn.Close()

	wire := captured.String()
	for _, marker := range []string{"wildpaqet", "WPQ", "h2", "http"} {
		if strings.Contains(wire, marker) {
			t.Fatalf("client-to-server bytes contain the marker %q", marker)
		}
	}
	// A TLS record header would start 0x16 0x03; the Noise handshake must not.
	raw := captured.Bytes()
	if len(raw) > 2 && raw[0] == 0x16 && raw[1] == 0x03 {
		t.Fatal("the first bytes look like a TLS record header")
	}
}

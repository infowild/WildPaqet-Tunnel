package tls

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestDecoyHasNoSharedWelcomeFallback(t *testing.T) {
	handler := newDecoyHandler("")
	for _, path := range []string{"/", "/missing", "/api/v1/events"} {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 404 || strings.Contains(w.Body.String(), "Welcome") {
			t.Fatalf("unexpected decoy: %d %s", w.Code, w.Body.String())
		}
	}
	expectedHost := ""
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != expectedHost {
			t.Error("invalid host")
		}
		if r.URL.Path == "/" {
			w.Write([]byte("real site"))
			return
		}
		http.NotFound(w, r)
	}))
	expectedHost = strings.TrimPrefix(backend.URL, "http://")
	proxy := newDecoyHandler(backend.URL)
	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, httptest.NewRequest("GET", "https://public.example/", nil))
	if w.Code != 200 || w.Body.String() != "real site" {
		t.Fatal("real site not served")
	}
	backend.Close()
	w = httptest.NewRecorder()
	proxy.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	if w.Code != 502 || strings.Contains(w.Body.String(), "Welcome") {
		t.Fatal("backend failure exposed shared page")
	}
}

func TestH2LargeTransfer(t *testing.T) {
	if os.Getenv("WILDPAQET_LARGE_TEST") != "1" {
		t.Skip("set WILDPAQET_LARGE_TEST=1 for 12 GiB echo (24 GiB duplex)")
	}
	cert, key := makeTestCertificate(t, "cover.example.test")
	serverCfg := testTLSConfig("0123456789abcdef0123456789abcdef")
	serverCfg.Mode = "h2"
	serverCfg.SmuxVersion = 2
	serverCfg.CertFile = cert
	serverCfg.KeyFile = key
	serverCfg.CoverPath = "/events"
	serverCfg.ServerName = "cover.example.test"
	listener, err := Listen("127.0.0.1:0", serverCfg)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	const total int64 = 12 << 30
	serverErr := make(chan error, 1)
	go func() {
		c, e := listener.Accept()
		if e != nil {
			serverErr <- e
			return
		}
		defer c.Close()
		s, e := c.AcceptStrm()
		if e != nil {
			serverErr <- e
			return
		}
		defer s.Close()
		_, e = io.CopyN(s, s, total)
		serverErr <- e
	}()
	cfg := *serverCfg
	cfg.CAFile = cert
	cfg.SendServerName = true
	cfg.ClientHello = "chrome"
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	conn, err := Dial(ctx, listener.Addr().String(), &cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	stream, err := conn.OpenStrm()
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	block := make([]byte, 128*1024)
	for i := range block {
		block[i] = byte(i*31 + i/256)
	}
	writeErr := make(chan error, 1)
	go func() {
		for sent := int64(0); sent < total; sent += int64(len(block)) {
			if e := writeAll(stream, block); e != nil {
				writeErr <- e
				return
			}
		}
		writeErr <- nil
	}()
	got := make([]byte, len(block))
	for read := int64(0); read < total; read += int64(len(got)) {
		if _, err = io.ReadFull(stream, got); err != nil {
			t.Fatalf("at %d bytes: %v", read, err)
		}
		if !bytes.Equal(got, block) {
			t.Fatal(fmt.Sprintf("data corruption at %d", read))
		}
	}
	if e := <-writeErr; e != nil {
		t.Fatal(e)
	}
	if e := <-serverErr; e != nil {
		t.Fatal(e)
	}
	t.Logf("verified %d bytes each direction over one smux v2 stream", total)
}

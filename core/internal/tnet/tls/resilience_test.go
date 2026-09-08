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

// The decoy must not be the same on every install.
//
// This replaces an earlier rule that forbade a welcome page outright. That rule
// was aimed at the right risk - a page shipped in the binary is identical
// everywhere, so one scan for it enumerates the fleet - but it paid for the fix
// by serving nothing at all, and a domain with a valid public certificate that
// answers 404 on "/" is its own anomaly. The identity is now derived from the
// shared secret instead, so the fleet is unlinkable while each host still looks
// like an ordinary server. What must hold is that two secrets differ.
func TestDecoyIdentityDiffersPerSecret(t *testing.T) {
	a := newDecoyIdentity([]byte("0123456789abcdef0123456789abcdef"))
	b := newDecoyIdentity([]byte("fedcba9876543210fedcba9876543210"))
	if a.server == b.server && a.etag == b.etag && a.modTime.Equal(b.modTime) {
		t.Fatal("two secrets produced an identical decoy identity")
	}
	if a.etag == b.etag {
		t.Fatalf("ETag is shared across installs: %s", a.etag)
	}

	// Stable across restarts: a real file does not change its date on reboot.
	again := newDecoyIdentity([]byte("0123456789abcdef0123456789abcdef"))
	if again.server != a.server || again.etag != a.etag || !again.modTime.Equal(a.modTime) {
		t.Fatal("identity is not stable for one secret")
	}

	// A page dated after the response carrying it is something no file can do.
	if a.modTime.After(time.Now()) {
		t.Fatalf("Last-Modified is in the future: %s", a.modTime)
	}

	// The version string and the markup have to belong to the same era.
	modern := strings.Contains(a.index, "color-scheme")
	if modern == strings.Contains(a.notFound, "bgcolor") {
		t.Fatal("index and error page come from different nginx generations")
	}
}

// A probe that replays the ETag must be answered 304, and Range/HEAD must behave
// as they would for a file on disk. Answering 200 to a conditional request is
// how a prober learns the page is generated rather than served.
func TestDecoyBehavesLikeAStaticFile(t *testing.T) {
	handler := newDecoyHandler("", []byte("0123456789abcdef0123456789abcdef"))

	w := httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	if w.Code != 200 {
		t.Fatalf("index returned %d", w.Code)
	}
	for _, h := range []string{"Server", "ETag", "Last-Modified", "Accept-Ranges", "Content-Length"} {
		if w.Header().Get(h) == "" {
			t.Fatalf("index response is missing %s", h)
		}
	}
	etag := w.Header().Get("ETag")

	cond := httptest.NewRequest("GET", "/", nil)
	cond.Header.Set("If-None-Match", etag)
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, cond)
	if w.Code != http.StatusNotModified {
		t.Fatalf("replayed ETag answered %d, want 304", w.Code)
	}

	rng := httptest.NewRequest("GET", "/", nil)
	rng.Header.Set("Range", "bytes=0-9")
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, rng)
	if w.Code != http.StatusPartialContent {
		t.Fatalf("range request answered %d, want 206", w.Code)
	}

	// Every path that is not the index is a 404 - the cover path included, so
	// it is not distinguishable from any other miss.
	for _, path := range []string{"/missing", "/api/v1/events", "/wp-login.php"} {
		w = httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 404 {
			t.Fatalf("%s answered %d, want 404", path, w.Code)
		}
		if strings.Contains(w.Body.String(), "404 page not found") {
			t.Fatalf("%s leaked Go's default body", path)
		}
		if w.Header().Get("Server") == "" {
			t.Fatalf("%s carries no Server header", path)
		}
	}
}

func TestDecoyProxiesAConfiguredSite(t *testing.T) {
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
	proxy := newDecoyHandler(backend.URL, []byte("0123456789abcdef0123456789abcdef"))
	w := httptest.NewRecorder()
	proxy.ServeHTTP(w, httptest.NewRequest("GET", "https://public.example/", nil))
	if w.Code != 200 || w.Body.String() != "real site" {
		t.Fatal("real site not served")
	}
	backend.Close()
	w = httptest.NewRecorder()
	proxy.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	if w.Code != 502 {
		t.Fatalf("backend failure answered %d, want 502", w.Code)
	}
	if w.Header().Get("Server") == "" {
		t.Fatal("backend failure exposed Go's plain-text error")
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

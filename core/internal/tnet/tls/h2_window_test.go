package tls

import (
	stdtls "crypto/tls"
	"net"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

func TestH2UploadWindowTracksSmuxBuffer(t *testing.T) {
	cases := []struct {
		name    string
		smuxbuf int
		want    int32
	}{
		{"below Go default is clamped up", 64 * 1024, h2MinUploadWindow},
		{"default smuxbuf", 4 * 1024 * 1024, 4 * 1024 * 1024},
		{"absurd value is clamped down", 1 << 30, h2MaxUploadWindow},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := h2UploadWindow(tc.smuxbuf); got != tc.want {
				t.Fatalf("h2UploadWindow(%d) = %d, want %d", tc.smuxbuf, got, tc.want)
			}
		})
	}
}

// TestH2ServerAdvertisesConfiguredUploadWindow reads the server's real SETTINGS
// frame off the wire. Go's HTTP/2 server defaults SETTINGS_INITIAL_WINDOW_SIZE
// to 1 MiB while its transport defaults the reverse direction to 4 MiB, which
// capped upload throughput at a quarter of download throughput on the same RTT.
func TestH2ServerAdvertisesConfiguredUploadWindow(t *testing.T) {
	certFile, keyFile := makeTestCertificate(t, "window.example.test")
	cfg := testTLSConfig("0123456789abcdef0123456789abcdef")
	cfg.Mode = "h2"
	cfg.ServerName = "window.example.test"
	cfg.CoverPath = "/api/v1/test/events"
	cfg.CertFile = certFile
	cfg.KeyFile = keyFile
	cfg.Smuxbuf = 4 * 1024 * 1024
	cfg.Streambuf = 2 * 1024 * 1024

	listener, err := Listen("127.0.0.1:0", cfg)
	if err != nil {
		t.Fatalf("listen h2: %v", err)
	}
	defer listener.Close()

	raw, err := stdtls.Dial("tcp", listener.Addr().String(), &stdtls.Config{
		InsecureSkipVerify: true, //nolint:gosec -- test-only probe of SETTINGS
		NextProtos:         []string{"h2"},
		ServerName:         "window.example.test",
	})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer raw.Close()
	if err := raw.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	if _, err := raw.Write([]byte(http2.ClientPreface)); err != nil {
		t.Fatalf("preface: %v", err)
	}

	framer := http2.NewFramer(raw, raw)
	if err := framer.WriteSettings(); err != nil {
		t.Fatalf("write settings: %v", err)
	}

	var (
		streamWindow int32 = -1
		connWindow   int32 = -1
	)
	for streamWindow < 0 || connWindow < 0 {
		frame, err := framer.ReadFrame()
		if err != nil {
			t.Fatalf("read frame: %v", err)
		}
		switch f := frame.(type) {
		case *http2.SettingsFrame:
			if v, ok := f.Value(http2.SettingInitialWindowSize); ok {
				streamWindow = int32(v)
			}
		case *http2.WindowUpdateFrame:
			if f.StreamID == 0 {
				// Go raises the connection window from the protocol's 65535
				// baseline with an immediate WINDOW_UPDATE.
				connWindow = 65535 + int32(f.Increment)
			}
		}
	}

	want := h2UploadWindow(cfg.Smuxbuf)
	if streamWindow != want {
		t.Fatalf("SETTINGS_INITIAL_WINDOW_SIZE = %d, want %d", streamWindow, want)
	}
	if connWindow != want {
		t.Fatalf("connection receive window = %d, want %d", connWindow, want)
	}
	if streamWindow <= h2MinUploadWindow {
		t.Fatalf("upload window %d is still at Go's 1 MiB default", streamWindow)
	}
}

var _ net.Conn = (*h2StreamConn)(nil)

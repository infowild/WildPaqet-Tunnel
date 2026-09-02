package conf

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestTLSClientConfigNeedsNoPCAPNetworkAndDistributesEndpoints(t *testing.T) {
	dir := t.TempDir()
	caFile := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(caFile, []byte("test fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "client.yaml")
	yaml := fmt.Sprintf(`
role: client
socks5:
  - listen: "127.0.0.1:1080"
server:
  addr: "203.0.113.10:443"
  addrs:
    - "203.0.113.11:443"
    - "203.0.113.12:443"
    - "203.0.113.13:443"
transport:
  protocol: tls
  tls:
    ca_file: %q
    secret: "0123456789abcdef0123456789abcdef"
`, caFile)
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadFromFile(path)
	if err != nil {
		t.Fatalf("load TLS client config: %v", err)
	}
	if cfg.Transport.Conn != 4 {
		t.Fatalf("conn = %d, want one connection for each of four endpoints", cfg.Transport.Conn)
	}
	if len(cfg.Server.Endpoints) != 4 {
		t.Fatalf("endpoints = %v, want four", cfg.Server.Endpoints)
	}
	if cfg.Transport.TLS.KeepAlive != 15*time.Second || cfg.Transport.TLS.KeepAliveTimeout != 60*time.Second {
		t.Fatalf("unexpected keepalive defaults: %s/%s", cfg.Transport.TLS.KeepAlive, cfg.Transport.TLS.KeepAliveTimeout)
	}
}

func TestTLSServerConfigNeedsNoPCAPNetwork(t *testing.T) {
	dir := t.TempDir()
	certFile := filepath.Join(dir, "server.crt")
	keyFile := filepath.Join(dir, "server.key")
	for _, path := range []string{certFile, keyFile} {
		if err := os.WriteFile(path, []byte("test fixture"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(dir, "server.yaml")
	yaml := fmt.Sprintf(`
role: server
listen:
  addr: ":443"
transport:
  protocol: tls
  tls:
    cert_file: %q
    key_file: %q
    secret: "0123456789abcdef0123456789abcdef"
`, certFile, keyFile)
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadFromFile(path)
	if err != nil {
		t.Fatalf("load TLS server config: %v", err)
	}
	if len(cfg.Listen.Endpoints) != 1 || cfg.Listen.Endpoints[0] != ":443" {
		t.Fatalf("listen endpoints = %v", cfg.Listen.Endpoints)
	}
}

func TestH2TLSClientDefaultsRequireVisibleSNIAndRotation(t *testing.T) {
	dir := t.TempDir()
	caFile := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(caFile, []byte("test fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "client-h2.yaml")
	yaml := fmt.Sprintf(`
role: client
forward:
  - listen: "127.0.0.1:9090"
    target: "127.0.0.1:9090"
server:
  addr: "203.0.113.10:443"
transport:
  protocol: tls
  tls:
    mode: h2
    server_name: cover.example.test
    send_server_name: true
    ca_file: %q
    secret: "0123456789abcdef0123456789abcdef"
`, caFile)
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadFromFile(path)
	if err != nil {
		t.Fatalf("load h2 config: %v", err)
	}
	tlsCfg := cfg.Transport.TLS
	if tlsCfg.CoverPath != defaultTLSCoverPath || tlsCfg.ClientHello != "chrome" {
		t.Fatalf("unexpected cover defaults: %q/%q", tlsCfg.CoverPath, tlsCfg.ClientHello)
	}
	if tlsCfg.MaxConnectionAge != 2*time.Hour || tlsCfg.DrainTimeout != 30*time.Minute {
		t.Fatalf("unexpected rotation defaults: %s/%s", tlsCfg.MaxConnectionAge, tlsCfg.DrainTimeout)
	}
}

func TestH2TLSClientRejectsHiddenSNI(t *testing.T) {
	tlsCfg := TLS{
		Mode:                 "h2",
		ServerName:           "cover.example.test",
		SendServerName:       false,
		Secret:               "0123456789abcdef0123456789abcdef",
		ALPN:                 "h2",
		CoverPath:            "/api/v1/events",
		ClientHello:          "chrome",
		ConnectTimeout_:      10,
		HandshakeTimeout_:    10,
		KeepAlive_:           15,
		KeepAliveTimeout_:    60,
		ConnectJitter_:       2,
		KeepAliveJitter_:     5,
		MaxConnectionAge_:    7200,
		ConnectionAgeJitter_: 1800,
		DrainTimeout_:        1800,
		BreakerFailures:      3,
		BreakerCooldown_:     30,
		BreakerMax_:          300,
		Smuxbuf:              1024,
		Streambuf:            1024,
	}
	if errs := tlsCfg.validate("client"); len(errs) == 0 {
		t.Fatal("h2 client with hidden SNI was accepted")
	}
}

func TestTLSSmuxVersionDefaults(t *testing.T) {
	cases := []struct {
		mode string
		want int
	}{
		// smux v1 ignores MaxStreamBuffer entirely, so streambuf was a dead
		// knob and one slow stream could stall the whole session.
		{"h2", 2},
		// Legacy direct mode stays wire-compatible with older peers.
		{"direct", 1},
	}
	for _, tc := range cases {
		t.Run(tc.mode, func(t *testing.T) {
			cfg := &TLS{Mode: tc.mode}
			cfg.setDefaults()
			if cfg.SmuxVersion != tc.want {
				t.Fatalf("mode %q defaulted smux_version to %d, want %d", tc.mode, cfg.SmuxVersion, tc.want)
			}
		})
	}
}

func TestTLSSmuxVersionExplicitValueIsKept(t *testing.T) {
	cfg := &TLS{Mode: "h2", SmuxVersion: 1}
	cfg.setDefaults()
	if cfg.SmuxVersion != 1 {
		t.Fatalf("explicit smux_version overwritten: got %d", cfg.SmuxVersion)
	}
}

func TestTLSRejectsInvalidSmuxVersion(t *testing.T) {
	cfg := baseH2ClientConfig()
	cfg.SmuxVersion = 3
	if !hasErrorContaining(cfg.validate("client"), "smux_version must be 1 or 2") {
		t.Fatal("expected smux_version validation error")
	}
}

func TestTLSRejectsStreambufLargerThanSmuxbuf(t *testing.T) {
	// smux itself refuses this pairing at session setup, which would otherwise
	// only surface as a dial failure at runtime.
	cfg := baseH2ClientConfig()
	cfg.Smuxbuf = 1024 * 1024
	cfg.Streambuf = 2 * 1024 * 1024
	if !hasErrorContaining(cfg.validate("client"), "streambuf must not exceed smuxbuf") {
		t.Fatal("expected streambuf/smuxbuf validation error")
	}
}

func baseH2ClientConfig() *TLS {
	cfg := &TLS{
		Mode:           "h2",
		ServerName:     "cover.example.test",
		SendServerName: true,
		CAFile:         "",
		Secret:         "0123456789abcdef0123456789abcdef",
	}
	cfg.setDefaults()
	return cfg
}

func hasErrorContaining(errs []error, want string) bool {
	for _, err := range errs {
		if strings.Contains(err.Error(), want) {
			return true
		}
	}
	return false
}

// TestManagerEmittedH2ClientConfigLoads pins the exact YAML the manager writes
// for a v3 client, including the throughput tuning keys, so a manager change
// that emits something the core rejects fails here rather than on a VPS.
func TestManagerEmittedH2ClientConfigLoads(t *testing.T) {
	dir := t.TempDir()
	caFile := filepath.Join(dir, "kharej-ca-bundle.crt")
	if err := os.WriteFile(caFile, []byte("test fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "client.yaml")
	yaml := fmt.Sprintf(`# WildPaqet v3 real HTTP/2-covered TLS client
role: "client"
log:
  level: "info"
forward:
  - listen: "0.0.0.0:9090"
    target: "127.0.0.1:9090"
    protocol: "tcp"
server:
  addr: "203.0.113.10:443"
  addrs:
    - "203.0.113.11:443"
transport:
  protocol: "tls"
  conn: 8
  tls:
    mode: "h2"
    server_name: "tunnel.example.com"
    send_server_name: true
    ca_file: %q
    secret: "0123456789abcdef0123456789abcdef"
    alpn: "h2"
    cover_path: "/api/v1/events"
    client_hello: "chrome"
    connect_jitter: 2
    keepalive_jitter: 5
    max_connection_age: 7200
    connection_age_jitter: 1800
    drain_timeout: 1800
    connect_timeout: 10
    handshake_timeout: 10
    keepalive: 15
    keepalive_timeout: 60
    breaker_failures: 3
    breaker_cooldown: 30
    breaker_max_cooldown: 300
    smuxbuf: 4194304
    streambuf: 2097152
    smux_version: 2
`, caFile)
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadFromFile(path)
	if err != nil {
		t.Fatalf("load manager-emitted v3 client config: %v", err)
	}
	tls := cfg.Transport.TLS
	if tls.Smuxbuf != 4*1024*1024 || tls.Streambuf != 2*1024*1024 {
		t.Fatalf("buffers = %d/%d, want 4194304/2097152", tls.Smuxbuf, tls.Streambuf)
	}
	if tls.SmuxVersion != 2 {
		t.Fatalf("smux_version = %d, want 2", tls.SmuxVersion)
	}
}

// TestLegacyH2ConfigGainsNewDefaults covers an install that predates the
// tuning keys: the core must supply them without the file being rewritten.
func TestLegacyH2ConfigGainsNewDefaults(t *testing.T) {
	dir := t.TempDir()
	caFile := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(caFile, []byte("test fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "client.yaml")
	yaml := fmt.Sprintf(`
role: "client"
server:
  addr: "203.0.113.10:443"
transport:
  protocol: "tls"
  tls:
    mode: "h2"
    server_name: "tunnel.example.com"
    send_server_name: true
    ca_file: %q
    secret: "0123456789abcdef0123456789abcdef"
    alpn: "h2"
    cover_path: "/api/v1/events"
`, caFile)
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadFromFile(path)
	if err != nil {
		t.Fatalf("load legacy v3 config: %v", err)
	}
	if cfg.Transport.TLS.SmuxVersion != 2 {
		t.Fatalf("smux_version = %d, want the v3 default of 2", cfg.Transport.TLS.SmuxVersion)
	}
	if cfg.Transport.TLS.Smuxbuf != defaultSmuxbuf {
		t.Fatalf("smuxbuf = %d, want %d", cfg.Transport.TLS.Smuxbuf, defaultSmuxbuf)
	}
	if cfg.Transport.TLS.Streambuf != defaultStreambuf {
		t.Fatalf("streambuf = %d, want %d", cfg.Transport.TLS.Streambuf, defaultStreambuf)
	}
}

// TestBufferDefaultsBalanceThroughputAgainstLatency pins both halves of the
// trade these numbers make, because both have bitten this project once.
//
// Too small and a single flow is capped however fast the link is: window/RTT is
// the ceiling, so 2 MiB is only ~168 Mbps at 100 ms. Too large and the standing
// queue one bulk transfer builds sits ahead of every other stream on the same
// multiplexed connection, which shows up as ping and jitter under load.
func TestBufferDefaultsBalanceThroughputAgainstLatency(t *testing.T) {
	const rttMs = 100
	mbps := func(window int) int { return window * 8 / rttMs / 1000 }

	// Floor: comfortably past the ~168 Mbps that 2 MiB allowed.
	if got := mbps(defaultStreambuf); got < 300 {
		t.Fatalf("streambuf caps one flow at %d Mbps over a 100 ms path", got)
	}
	// Ceiling: a bulk transfer may not park more than this ahead of every
	// other stream on the same connection.
	if got := mbps(defaultStreambuf); got > 400 {
		t.Fatalf("streambuf allows %d Mbps of standing queue per flow; that is latency, not speed", got)
	}
	// The outer TCP receive window is the next ceiling up, and the network
	// optimizer holds it at 8 MB so hosts keep advertising window scale 7.
	const optimizerTCPWindow = 8000000
	if defaultStreambuf > optimizerTCPWindow {
		t.Fatalf("streambuf %d exceeds the outer TCP window the optimizer allows", defaultStreambuf)
	}
	if defaultStreambuf > defaultSmuxbuf {
		t.Fatalf("streambuf %d exceeds smuxbuf %d; smux rejects that pairing", defaultStreambuf, defaultSmuxbuf)
	}
}

package conf

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The stealth carrier has no TLS, so demanding a certificate, an ALPN or an SNI
// there would ask an operator to install material nothing reads.
func TestStealthNeedsNoCertificateOrALPN(t *testing.T) {
	for _, role := range []string{"server", "client"} {
		cfg := &TLS{Mode: "stealth", Secret: strings.Repeat("s", 40)}
		cfg.setDefaults()
		for _, err := range cfg.validate(role) {
			t.Errorf("%s: stealth config rejected: %v", role, err)
		}
	}
}

func TestStealthStillRequiresASecret(t *testing.T) {
	cfg := &TLS{Mode: "stealth", Secret: "short"}
	cfg.setDefaults()
	if !hasErrorContaining(cfg.validate("client"), "at least 32 characters") {
		t.Fatal("a short secret was accepted on the stealth carrier")
	}
}

// Padding changes the framing between the two smux endpoints, and only the h2
// carrier has an opt-in for it: the stealth carrier always pads and direct TLS
// has no support at all.
func TestPaddingIsH2Only(t *testing.T) {
	h2 := baseH2ClientConfig()
	h2.Padding = true
	if errs := h2.validate("client"); len(errs) != 0 {
		t.Fatalf("h2 rejected padding: %v", errs)
	}
	for _, mode := range []string{"direct", "stealth"} {
		cfg := &TLS{Mode: mode, ServerName: "x.example", Secret: strings.Repeat("s", 40), Padding: true}
		cfg.setDefaults()
		if !hasErrorContaining(cfg.validate("client"), "padding is only available in h2") {
			t.Fatalf("%s accepted the padding flag", mode)
		}
	}
}

// The exact YAML the manager's stealth wizard writes has to load.
func TestManagerStealthYAMLLoads(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct {
		name string
		body string
	}{
		{"server", `role: "server"
log:
  level: "info"
listen:
  addr: ":443"
transport:
  protocol: "tls"
  conn: 1
  tls:
    mode: "stealth"
    secret: "0123456789abcdef0123456789abcdef0123"
    connect_timeout: 10
    handshake_timeout: 10
    keepalive: 15
    keepalive_timeout: 60
    connect_jitter: 2
    keepalive_jitter: 5
    breaker_failures: 3
    breaker_cooldown: 30
    breaker_max_cooldown: 300
    smuxbuf: 8388608
    streambuf: 4194304
    smux_version: 2
`},
		{"client", `role: "client"
log:
  level: "info"
forward:
  - listen: "0.0.0.0:8443"
    target: "127.0.0.1:8443"
    protocol: "tcp"
server:
  addr: "203.0.113.10:443"
  addrs:
    - "203.0.113.11:443"
transport:
  protocol: "tls"
  conn: 8
  tls:
    mode: "stealth"
    secret: "0123456789abcdef0123456789abcdef0123"
    connect_timeout: 10
    handshake_timeout: 10
    keepalive: 15
    keepalive_timeout: 60
    connect_jitter: 2
    keepalive_jitter: 5
    breaker_failures: 3
    breaker_cooldown: 30
    breaker_max_cooldown: 300
    smuxbuf: 8388608
    streambuf: 4194304
    smux_version: 2
`},
	} {
		path := filepath.Join(dir, tc.name+".yaml")
		if err := os.WriteFile(path, []byte(tc.body), 0o600); err != nil {
			t.Fatal(err)
		}
		cfg, err := LoadFromFile(path)
		if err != nil {
			t.Fatalf("%s: the wizard's stealth config does not load: %v", tc.name, err)
		}
		if cfg.Transport.TLS.Mode != "stealth" {
			t.Fatalf("%s: mode came back as %q", tc.name, cfg.Transport.TLS.Mode)
		}
	}
}

// The h2 wizard now writes a padding key; it must round-trip.
func TestManagerH2PaddingYAMLLoads(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "client.yaml")
	body := `role: "client"
log:
  level: "info"
forward:
  - listen: "0.0.0.0:8443"
    target: "127.0.0.1:8443"
    protocol: "tcp"
server:
  addr: "203.0.113.10:443"
transport:
  protocol: "tls"
  conn: 4
  tls:
    mode: "h2"
    server_name: "cover.example.test"
    send_server_name: true
    secret: "0123456789abcdef0123456789abcdef0123"
    alpn: "h2"
    cover_path: "/api/v1/events"
    padding: true
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
    smuxbuf: 8388608
    streambuf: 4194304
    smux_version: 2
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadFromFile(path)
	if err != nil {
		t.Fatalf("the wizard's padded h2 config does not load: %v", err)
	}
	if !cfg.Transport.TLS.Padding {
		t.Fatal("padding: true did not survive the round trip")
	}
}

package conf

import (
	"fmt"
	"os"
	"path/filepath"
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

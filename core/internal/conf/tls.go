package conf

import (
	"fmt"
	"net/url"
	"os"
	"path"
	"slices"
	"strings"
	"time"
)

// Buffer defaults trade throughput against latency, and both directions of
// that trade are real.
//
// Every window here bounds in-flight bytes to window/RTT, so a LAN-sized value
// caps a single flow on a WAN path no matter how fast the link is: 2 MiB is
// only ~170 Mbps at 100 ms. But smux multiplexes every user connection onto one
// TCP stream, so whatever one bulk transfer has outstanding also sits ahead of
// every other stream on that connection. Oversizing these therefore shows up as
// ping and jitter climbing whenever the tunnel is busy - measurably so on a
// path with deep buffers, which describes most consumer routes.
//
// 8 MiB / 4 MiB is the middle of that trade: roughly 340 Mbps for one flow at
// 100 ms RTT, without the standing queue that 8 MiB of streambuf builds. Raise
// them for a fast, well-buffered path; lower them if interactive latency under
// load matters more than bulk speed.
const (
	defaultSmuxbuf   = 8 * 1024 * 1024
	defaultStreambuf = 4 * 1024 * 1024
)

const (
	defaultTLSALPN      = "h2"
	defaultTLSMode      = "direct"
	defaultTLSCoverPath = "/api/v1/events"
)

// TLS configures both the v3 HTTP/2-covered and legacy direct TLS transports.
// The shared secret authenticates the client inside TLS and must be independent
// from any legacy KCP key.
type TLS struct {
	Mode           string `yaml:"mode"`
	ServerName     string `yaml:"server_name"`
	SendServerName bool   `yaml:"send_server_name"`
	CertFile       string `yaml:"cert_file"`
	KeyFile        string `yaml:"key_file"`
	CAFile         string `yaml:"ca_file"`
	Secret         string `yaml:"secret"`
	ALPN           string `yaml:"alpn"`
	CoverPath      string `yaml:"cover_path"`
	DecoyURL       string `yaml:"decoy_url"`
	ClientHello    string `yaml:"client_hello"`

	ConnectTimeout_      int `yaml:"connect_timeout"`
	HandshakeTimeout_    int `yaml:"handshake_timeout"`
	KeepAlive_           int `yaml:"keepalive"`
	KeepAliveTimeout_    int `yaml:"keepalive_timeout"`
	ConnectJitter_       int `yaml:"connect_jitter"`
	KeepAliveJitter_     int `yaml:"keepalive_jitter"`
	MaxConnectionAge_    int `yaml:"max_connection_age"`
	ConnectionAgeJitter_ int `yaml:"connection_age_jitter"`
	DrainTimeout_        int `yaml:"drain_timeout"`
	BreakerFailures      int `yaml:"breaker_failures"`
	BreakerCooldown_     int `yaml:"breaker_cooldown"`
	BreakerMax_          int `yaml:"breaker_max_cooldown"`
	Smuxbuf              int `yaml:"smuxbuf"`
	Streambuf            int `yaml:"streambuf"`
	SmuxVersion          int `yaml:"smux_version"`

	ConnectTimeout      time.Duration `yaml:"-"`
	HandshakeTimeout    time.Duration `yaml:"-"`
	KeepAlive           time.Duration `yaml:"-"`
	KeepAliveTimeout    time.Duration `yaml:"-"`
	ConnectJitter       time.Duration `yaml:"-"`
	KeepAliveJitter     time.Duration `yaml:"-"`
	MaxConnectionAge    time.Duration `yaml:"-"`
	ConnectionAgeJitter time.Duration `yaml:"-"`
	DrainTimeout        time.Duration `yaml:"-"`
	BreakerCooldown     time.Duration `yaml:"-"`
	BreakerMax          time.Duration `yaml:"-"`
}

func (t *TLS) setDefaults() {
	if t.Mode == "" {
		t.Mode = defaultTLSMode
	}
	if t.ALPN == "" {
		t.ALPN = defaultTLSALPN
	}
	if t.Mode == "h2" {
		if t.CoverPath == "" {
			t.CoverPath = defaultTLSCoverPath
		}
		if t.ClientHello == "" {
			t.ClientHello = "chrome"
		}
		if t.ConnectJitter_ == 0 {
			t.ConnectJitter_ = 2
		}
		if t.KeepAliveJitter_ == 0 {
			t.KeepAliveJitter_ = 5
		}
		if t.MaxConnectionAge_ == 0 {
			t.MaxConnectionAge_ = 7200
		}
		if t.ConnectionAgeJitter_ == 0 {
			t.ConnectionAgeJitter_ = 1800
		}
		if t.DrainTimeout_ == 0 {
			t.DrainTimeout_ = 1800
		}
	}
	if t.ConnectTimeout_ == 0 {
		t.ConnectTimeout_ = 10
	}
	if t.HandshakeTimeout_ == 0 {
		t.HandshakeTimeout_ = 10
	}
	if t.KeepAlive_ == 0 {
		t.KeepAlive_ = 15
	}
	if t.KeepAliveTimeout_ == 0 {
		t.KeepAliveTimeout_ = 60
	}
	if t.BreakerFailures == 0 {
		t.BreakerFailures = 3
	}
	if t.BreakerCooldown_ == 0 {
		t.BreakerCooldown_ = 30
	}
	if t.BreakerMax_ == 0 {
		t.BreakerMax_ = 300
	}
	if t.Smuxbuf == 0 {
		t.Smuxbuf = defaultSmuxbuf
	}
	if t.Streambuf == 0 {
		t.Streambuf = defaultStreambuf
	}
	if t.SmuxVersion == 0 {
		// smux v1 has no per-stream flow control: it ignores MaxStreamBuffer
		// entirely and lets a single slow stream drain the shared session
		// bucket, stalling every other stream on the same outer connection.
		// v3 transports therefore default to v2. Legacy direct mode keeps v1
		// so it stays wire-compatible with older peers.
		if t.Mode == "h2" {
			t.SmuxVersion = 2
		} else {
			t.SmuxVersion = 1
		}
	}
}

func (t *TLS) validate(role string) []error {
	var errors []error
	if !slices.Contains([]string{"direct", "h2"}, t.Mode) {
		errors = append(errors, fmt.Errorf("TLS mode must be one of: direct, h2"))
	}
	if len(t.Secret) < 32 {
		errors = append(errors, fmt.Errorf("TLS secret must be at least 32 characters"))
	}
	if t.ALPN != defaultTLSALPN {
		errors = append(errors, fmt.Errorf("TLS alpn must be %q", defaultTLSALPN))
	}
	if t.ConnectTimeout_ < 1 || t.ConnectTimeout_ > 60 {
		errors = append(errors, fmt.Errorf("TLS connect_timeout must be between 1-60 seconds"))
	}
	if t.HandshakeTimeout_ < 1 || t.HandshakeTimeout_ > 60 {
		errors = append(errors, fmt.Errorf("TLS handshake_timeout must be between 1-60 seconds"))
	}
	if t.KeepAlive_ < 5 || t.KeepAlive_ > 300 {
		errors = append(errors, fmt.Errorf("TLS keepalive must be between 5-300 seconds"))
	}
	if t.KeepAliveTimeout_ <= t.KeepAlive_ || t.KeepAliveTimeout_ > 900 {
		errors = append(errors, fmt.Errorf("TLS keepalive_timeout must be greater than keepalive and at most 900 seconds"))
	}
	if t.Mode == "h2" {
		if t.ALPN != "h2" {
			errors = append(errors, fmt.Errorf("TLS h2 mode requires alpn %q", defaultTLSALPN))
		}
		if !strings.HasPrefix(t.CoverPath, "/") || strings.ContainsAny(t.CoverPath, "?#\r\n") || len(t.CoverPath) > 160 || path.Clean(t.CoverPath) != t.CoverPath {
			errors = append(errors, fmt.Errorf("TLS cover_path must be an absolute path without a query or fragment"))
		}
		if !slices.Contains([]string{"chrome", "firefox", "randomized"}, t.ClientHello) {
			errors = append(errors, fmt.Errorf("TLS client_hello must be one of: chrome, firefox, randomized"))
		}
		if role == "client" && (t.ServerName == "" || !t.SendServerName) {
			errors = append(errors, fmt.Errorf("TLS h2 mode requires server_name and send_server_name: true"))
		}
		if t.DecoyURL != "" {
			u, err := url.Parse(t.DecoyURL)
			if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil {
				errors = append(errors, fmt.Errorf("TLS decoy_url must be an http(s) URL without credentials"))
			}
		}
		if t.ConnectJitter_ < 0 || t.ConnectJitter_ > 30 {
			errors = append(errors, fmt.Errorf("TLS connect_jitter must be between 0-30 seconds"))
		}
		if t.KeepAliveJitter_ < 0 || t.KeepAliveJitter_ >= t.KeepAlive_ {
			errors = append(errors, fmt.Errorf("TLS keepalive_jitter must be non-negative and less than keepalive"))
		}
		if t.MaxConnectionAge_ < 300 || t.MaxConnectionAge_ > 86400 {
			errors = append(errors, fmt.Errorf("TLS max_connection_age must be between 300-86400 seconds"))
		}
		if t.ConnectionAgeJitter_ < 0 || t.ConnectionAgeJitter_ >= t.MaxConnectionAge_/2 {
			errors = append(errors, fmt.Errorf("TLS connection_age_jitter must be non-negative and less than half max_connection_age"))
		}
		if t.DrainTimeout_ < 60 || t.DrainTimeout_ > 7200 {
			errors = append(errors, fmt.Errorf("TLS drain_timeout must be between 60-7200 seconds"))
		}
	}
	if t.BreakerFailures < 1 || t.BreakerFailures > 20 {
		errors = append(errors, fmt.Errorf("TLS breaker_failures must be between 1-20"))
	}
	if t.BreakerCooldown_ < 5 || t.BreakerCooldown_ > 300 {
		errors = append(errors, fmt.Errorf("TLS breaker_cooldown must be between 5-300 seconds"))
	}
	if t.BreakerMax_ < t.BreakerCooldown_ || t.BreakerMax_ > 1800 {
		errors = append(errors, fmt.Errorf("TLS breaker_max_cooldown must be >= breaker_cooldown and at most 1800 seconds"))
	}
	if t.Smuxbuf < 1024 {
		errors = append(errors, fmt.Errorf("TLS smuxbuf must be >= 1024 bytes"))
	}
	if t.Streambuf < 1024 {
		errors = append(errors, fmt.Errorf("TLS streambuf must be >= 1024 bytes"))
	}
	if t.Streambuf > t.Smuxbuf {
		errors = append(errors, fmt.Errorf("TLS streambuf must not exceed smuxbuf"))
	}
	if t.SmuxVersion != 1 && t.SmuxVersion != 2 {
		errors = append(errors, fmt.Errorf("TLS smux_version must be 1 or 2"))
	}

	if role == "server" {
		if t.CertFile == "" || t.KeyFile == "" {
			errors = append(errors, fmt.Errorf("TLS cert_file and key_file are required on the server"))
		} else {
			if _, err := os.Stat(t.CertFile); err != nil {
				errors = append(errors, fmt.Errorf("TLS cert_file: %v", err))
			}
			if _, err := os.Stat(t.KeyFile); err != nil {
				errors = append(errors, fmt.Errorf("TLS key_file: %v", err))
			}
		}
	} else {
		if t.CAFile != "" {
			if _, err := os.Stat(t.CAFile); err != nil {
				errors = append(errors, fmt.Errorf("TLS ca_file: %v", err))
			}
		} else if t.ServerName == "" {
			errors = append(errors, fmt.Errorf("TLS server_name is required when ca_file is not set"))
		}
		if t.SendServerName && t.ServerName == "" {
			errors = append(errors, fmt.Errorf("TLS server_name is required when send_server_name is true"))
		}
	}

	t.ConnectTimeout = time.Duration(t.ConnectTimeout_) * time.Second
	t.HandshakeTimeout = time.Duration(t.HandshakeTimeout_) * time.Second
	t.KeepAlive = time.Duration(t.KeepAlive_) * time.Second
	t.KeepAliveTimeout = time.Duration(t.KeepAliveTimeout_) * time.Second
	t.ConnectJitter = time.Duration(t.ConnectJitter_) * time.Second
	t.KeepAliveJitter = time.Duration(t.KeepAliveJitter_) * time.Second
	t.MaxConnectionAge = time.Duration(t.MaxConnectionAge_) * time.Second
	t.ConnectionAgeJitter = time.Duration(t.ConnectionAgeJitter_) * time.Second
	t.DrainTimeout = time.Duration(t.DrainTimeout_) * time.Second
	t.BreakerCooldown = time.Duration(t.BreakerCooldown_) * time.Second
	t.BreakerMax = time.Duration(t.BreakerMax_) * time.Second
	return errors
}

package conf

import (
	"fmt"
	"os"
	"time"
)

const defaultTLSALPN = "h2"

// TLS configures the v3 direct TLS transport. The shared secret authenticates
// the client after TLS and must be independent from any legacy KCP key.
type TLS struct {
	ServerName     string `yaml:"server_name"`
	SendServerName bool   `yaml:"send_server_name"`
	CertFile       string `yaml:"cert_file"`
	KeyFile        string `yaml:"key_file"`
	CAFile         string `yaml:"ca_file"`
	Secret         string `yaml:"secret"`
	ALPN           string `yaml:"alpn"`

	ConnectTimeout_   int `yaml:"connect_timeout"`
	HandshakeTimeout_ int `yaml:"handshake_timeout"`
	KeepAlive_        int `yaml:"keepalive"`
	KeepAliveTimeout_ int `yaml:"keepalive_timeout"`
	BreakerFailures   int `yaml:"breaker_failures"`
	BreakerCooldown_  int `yaml:"breaker_cooldown"`
	BreakerMax_       int `yaml:"breaker_max_cooldown"`
	Smuxbuf           int `yaml:"smuxbuf"`
	Streambuf         int `yaml:"streambuf"`

	ConnectTimeout   time.Duration `yaml:"-"`
	HandshakeTimeout time.Duration `yaml:"-"`
	KeepAlive        time.Duration `yaml:"-"`
	KeepAliveTimeout time.Duration `yaml:"-"`
	BreakerCooldown  time.Duration `yaml:"-"`
	BreakerMax       time.Duration `yaml:"-"`
}

func (t *TLS) setDefaults() {
	if t.ALPN == "" {
		t.ALPN = defaultTLSALPN
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
		t.Smuxbuf = 4 * 1024 * 1024
	}
	if t.Streambuf == 0 {
		t.Streambuf = 2 * 1024 * 1024
	}
}

func (t *TLS) validate(role string) []error {
	var errors []error
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
	t.BreakerCooldown = time.Duration(t.BreakerCooldown_) * time.Second
	t.BreakerMax = time.Duration(t.BreakerMax_) * time.Second
	return errors
}

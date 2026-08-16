package tls

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"

	"github.com/xtaci/smux"

	"paqet/internal/conf"
)

func clientTLSConfig(cfg *conf.TLS) (*tls.Config, error) {
	roots, err := x509.SystemCertPool()
	if err != nil || roots == nil {
		roots = x509.NewCertPool()
	}
	if cfg.CAFile != "" {
		pem, err := os.ReadFile(cfg.CAFile)
		if err != nil {
			return nil, fmt.Errorf("read CA file: %w", err)
		}
		if !roots.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("CA file contains no valid certificates")
		}
	}
	tlsCfg := &tls.Config{
		MinVersion: tls.VersionTLS13,
		RootCAs:    roots,
		NextProtos: []string{cfg.ALPN},
	}
	if cfg.SendServerName {
		tlsCfg.ServerName = cfg.ServerName
		return tlsCfg, nil
	}

	// Keep SNI off the wire for private/self-signed deployments while still
	// performing normal x509 chain verification below. InsecureSkipVerify only
	// disables the built-in hostname pass; VerifyConnection replaces it.
	tlsCfg.InsecureSkipVerify = true //nolint:gosec -- verified in VerifyConnection
	tlsCfg.VerifyConnection = func(state tls.ConnectionState) error {
		if len(state.PeerCertificates) == 0 {
			return fmt.Errorf("TLS peer sent no certificate")
		}
		intermediates := x509.NewCertPool()
		for _, certificate := range state.PeerCertificates[1:] {
			intermediates.AddCert(certificate)
		}
		_, err := state.PeerCertificates[0].Verify(x509.VerifyOptions{
			DNSName:       cfg.ServerName,
			Roots:         roots,
			Intermediates: intermediates,
			KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		})
		return err
	}
	return tlsCfg, nil
}

func serverTLSConfig(cfg *conf.TLS) (*tls.Config, error) {
	certificate, err := tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("load TLS certificate: %w", err)
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{certificate},
		NextProtos:   []string{cfg.ALPN},
	}, nil
}

func smuxConfig(cfg *conf.TLS) *smux.Config {
	sc := smux.DefaultConfig()
	sc.MaxReceiveBuffer = cfg.Smuxbuf
	sc.MaxStreamBuffer = cfg.Streambuf
	sc.KeepAliveInterval = cfg.KeepAlive
	sc.KeepAliveTimeout = cfg.KeepAliveTimeout
	return sc
}

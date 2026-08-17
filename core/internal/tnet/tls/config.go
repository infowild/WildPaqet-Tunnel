package tls

import (
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"math/big"
	"os"
	"sync"
	"time"

	"github.com/xtaci/smux"

	"paqet/internal/conf"
)

func clientTLSConfig(cfg *conf.TLS) (*tls.Config, error) {
	roots, err := clientRootPool(cfg)
	if err != nil {
		return nil, err
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

func clientRootPool(cfg *conf.TLS) (*x509.CertPool, error) {
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
	return roots, nil
}

func serverTLSConfig(cfg *conf.TLS) (*tls.Config, error) {
	reloader, err := newCertificateReloader(cfg.CertFile, cfg.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("load TLS certificate: %w", err)
	}
	return &tls.Config{
		MinVersion:     tls.VersionTLS13,
		GetCertificate: reloader.getCertificate,
		NextProtos:     []string{cfg.ALPN},
	}, nil
}

type certificateReloader struct {
	certFile string
	keyFile  string

	mu          sync.Mutex
	certificate *tls.Certificate
	certModTime time.Time
	keyModTime  time.Time
}

func newCertificateReloader(certFile, keyFile string) (*certificateReloader, error) {
	r := &certificateReloader{certFile: certFile, keyFile: keyFile}
	if _, err := r.load(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *certificateReloader) getCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	return r.load()
}

func (r *certificateReloader) load() (*tls.Certificate, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	certInfo, err := os.Stat(r.certFile)
	if err != nil {
		return nil, err
	}
	keyInfo, err := os.Stat(r.keyFile)
	if err != nil {
		return nil, err
	}
	if r.certificate != nil && certInfo.ModTime().Equal(r.certModTime) && keyInfo.ModTime().Equal(r.keyModTime) {
		return r.certificate, nil
	}
	certificate, err := tls.LoadX509KeyPair(r.certFile, r.keyFile)
	if err != nil {
		// ACME clients can replace the two paths a fraction of a second apart.
		// Keep serving the last valid pair during that window and retry on the
		// next handshake instead of creating a renewal-time outage.
		if r.certificate != nil {
			return r.certificate, nil
		}
		return nil, err
	}
	r.certificate = &certificate
	r.certModTime = certInfo.ModTime()
	r.keyModTime = keyInfo.ModTime()
	return r.certificate, nil
}

func smuxConfig(cfg *conf.TLS) *smux.Config {
	sc := smux.DefaultConfig()
	sc.MaxReceiveBuffer = cfg.Smuxbuf
	sc.MaxStreamBuffer = cfg.Streambuf
	sc.KeepAliveInterval = jitterDuration(cfg.KeepAlive, cfg.KeepAliveJitter)
	sc.KeepAliveTimeout = cfg.KeepAliveTimeout
	return sc
}

func jitterDuration(base, jitter time.Duration) time.Duration {
	if jitter <= 0 {
		return base
	}
	span := int64(2*jitter) + 1
	n, err := rand.Int(rand.Reader, big.NewInt(span))
	if err != nil {
		return base
	}
	return base - jitter + time.Duration(n.Int64())
}

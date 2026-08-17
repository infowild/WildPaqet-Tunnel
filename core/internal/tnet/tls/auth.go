package tls

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

const (
	authMagic       = "WPQ3"
	authRequestSize = 4 + 1 + 8 + 32 + sha256.Size
	authReplySize   = 4 + sha256.Size
	authVersion     = byte(1)
	coverAuthLabel  = "wildpaqet-h2-cover-v1"
	coverTokenSize  = 1 + 8 + 32 + sha256.Size
	authClockSkew   = 2 * time.Minute
	replayLifetime  = 5 * time.Minute
)

func createCoverToken(secret []byte, path string, now time.Time) (string, error) {
	token := make([]byte, coverTokenSize)
	token[0] = authVersion
	binary.BigEndian.PutUint64(token[1:9], uint64(now.Unix()))
	if _, err := rand.Read(token[9:41]); err != nil {
		return "", fmt.Errorf("h2 auth nonce: %w", err)
	}
	copy(token[41:], coverTokenMAC(secret, path, token[:41]))
	return base64.RawURLEncoding.EncodeToString(token), nil
}

func verifyCoverToken(encoded string, secret []byte, path string, cache *replayCache, now time.Time) error {
	token, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(token) != coverTokenSize {
		return fmt.Errorf("h2 auth token is invalid")
	}
	if token[0] != authVersion {
		return fmt.Errorf("h2 auth version is invalid")
	}
	stamp := int64(binary.BigEndian.Uint64(token[1:9]))
	delta := now.Sub(time.Unix(stamp, 0))
	if delta < -authClockSkew || delta > authClockSkew {
		return fmt.Errorf("h2 auth timestamp outside allowed clock skew")
	}
	want := coverTokenMAC(secret, path, token[:41])
	if subtle.ConstantTimeCompare(token[41:], want) != 1 {
		return fmt.Errorf("h2 auth MAC is invalid")
	}
	var nonce [32]byte
	copy(nonce[:], token[9:41])
	if !cache.accept(nonce, now) {
		return fmt.Errorf("h2 auth replay rejected")
	}
	return nil
}

func coverTokenMAC(secret []byte, path string, prefix []byte) []byte {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(coverAuthLabel))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(path))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write(prefix)
	return mac.Sum(nil)
}

type replayCache struct {
	mu      sync.Mutex
	entries map[[32]byte]time.Time
}

func newReplayCache() *replayCache {
	return &replayCache{entries: make(map[[32]byte]time.Time)}
}

func (r *replayCache) accept(nonce [32]byte, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for key, expiry := range r.entries {
		if !expiry.After(now) {
			delete(r.entries, key)
		}
	}
	if _, exists := r.entries[nonce]; exists {
		return false
	}
	r.entries[nonce] = now.Add(replayLifetime)
	return true
}

func authenticateClient(conn net.Conn, secret []byte, now time.Time) error {
	request := make([]byte, authRequestSize)
	copy(request[:4], authMagic)
	request[4] = authVersion
	binary.BigEndian.PutUint64(request[5:13], uint64(now.Unix()))
	if _, err := rand.Read(request[13:45]); err != nil {
		return fmt.Errorf("tls auth nonce: %w", err)
	}
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write(request[:45])
	copy(request[45:], mac.Sum(nil))
	if err := writeAll(conn, request); err != nil {
		return fmt.Errorf("tls auth request: %w", err)
	}

	reply := make([]byte, authReplySize)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return fmt.Errorf("tls auth reply: %w", err)
	}
	if string(reply[:4]) != authMagic {
		return fmt.Errorf("tls auth reply has invalid magic")
	}
	want := authReplyMAC(secret, request[13:45])
	if subtle.ConstantTimeCompare(reply[4:], want) != 1 {
		return fmt.Errorf("tls auth reply MAC is invalid")
	}
	return nil
}

func authenticateServer(conn net.Conn, secret []byte, cache *replayCache, now time.Time) error {
	request := make([]byte, authRequestSize)
	if _, err := io.ReadFull(conn, request); err != nil {
		return fmt.Errorf("tls auth request: %w", err)
	}
	if string(request[:4]) != authMagic || request[4] != authVersion {
		return fmt.Errorf("tls auth request has invalid header")
	}
	stamp := int64(binary.BigEndian.Uint64(request[5:13]))
	delta := now.Sub(time.Unix(stamp, 0))
	if delta < -authClockSkew || delta > authClockSkew {
		return fmt.Errorf("tls auth timestamp outside allowed clock skew")
	}
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write(request[:45])
	if subtle.ConstantTimeCompare(request[45:], mac.Sum(nil)) != 1 {
		return fmt.Errorf("tls auth request MAC is invalid")
	}
	var nonce [32]byte
	copy(nonce[:], request[13:45])
	if !cache.accept(nonce, now) {
		return fmt.Errorf("tls auth replay rejected")
	}

	reply := make([]byte, authReplySize)
	copy(reply[:4], authMagic)
	copy(reply[4:], authReplyMAC(secret, nonce[:]))
	if err := writeAll(conn, reply); err != nil {
		return fmt.Errorf("tls auth reply: %w", err)
	}
	return nil
}

func authReplyMAC(secret, nonce []byte) []byte {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte("wildpaqet-v3-server"))
	_, _ = mac.Write(nonce)
	return mac.Sum(nil)
}

func writeAll(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := w.Write(data)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrUnexpectedEOF
		}
		data = data[n:]
	}
	return nil
}

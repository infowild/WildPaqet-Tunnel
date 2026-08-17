package tls

import (
	"net"
	"testing"
	"time"
)

func TestAuthenticationRoundTrip(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	serverErr := make(chan error, 1)
	go func() {
		serverErr <- authenticateServer(server, secret, newReplayCache(), time.Now())
	}()
	if err := authenticateClient(client, secret, time.Now()); err != nil {
		t.Fatalf("client authentication failed: %v", err)
	}
	if err := <-serverErr; err != nil {
		t.Fatalf("server authentication failed: %v", err)
	}
}

func TestAuthenticationFailsClosedWithWrongSecret(t *testing.T) {
	serverSecret := []byte("0123456789abcdef0123456789abcdef")
	clientSecret := []byte("fedcba9876543210fedcba9876543210")
	client, server := net.Pipe()

	serverErr := make(chan error, 1)
	go func() {
		err := authenticateServer(server, serverSecret, newReplayCache(), time.Now())
		_ = server.Close()
		serverErr <- err
	}()
	clientErr := authenticateClient(client, clientSecret, time.Now())
	_ = client.Close()
	if clientErr == nil {
		t.Fatal("client accepted a server response after using the wrong secret")
	}
	if err := <-serverErr; err == nil {
		t.Fatal("server accepted a client with the wrong secret")
	}
}

func TestAuthenticationRejectsTimestampOutsideWindow(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	client, server := net.Pipe()

	serverErr := make(chan error, 1)
	go func() {
		err := authenticateServer(server, secret, newReplayCache(), time.Now())
		_ = server.Close()
		serverErr <- err
	}()
	clientErr := authenticateClient(client, secret, time.Now().Add(-authClockSkew-time.Second))
	_ = client.Close()
	if clientErr == nil {
		t.Fatal("client unexpectedly authenticated with a stale timestamp")
	}
	if err := <-serverErr; err == nil {
		t.Fatal("server accepted a stale authentication timestamp")
	}
}

func TestReplayCacheAllowsSingleUse(t *testing.T) {
	cache := newReplayCache()
	now := time.Now()
	var nonce [32]byte
	nonce[0] = 1
	if !cache.accept(nonce, now) {
		t.Fatal("first nonce use was rejected")
	}
	if cache.accept(nonce, now.Add(time.Second)) {
		t.Fatal("replayed nonce was accepted")
	}
	if !cache.accept(nonce, now.Add(replayLifetime+time.Second)) {
		t.Fatal("expired replay-cache entry was not pruned")
	}
}

func TestH2CoverAuthenticationRejectsTamperReplayAndStaleTokens(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	path := "/api/v1/private/events"
	now := time.Now()
	token, err := createCoverToken(secret, path, now)
	if err != nil {
		t.Fatal(err)
	}
	cache := newReplayCache()
	if err := verifyCoverToken(token, secret, path, cache, now); err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	if err := verifyCoverToken(token, secret, path, cache, now); err == nil {
		t.Fatal("replayed h2 token was accepted")
	}
	if err := verifyCoverToken(token, secret, path+"-tampered", newReplayCache(), now); err == nil {
		t.Fatal("token was accepted for a different cover path")
	}
	stale, err := createCoverToken(secret, path, now.Add(-authClockSkew-time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyCoverToken(stale, secret, path, newReplayCache(), now); err == nil {
		t.Fatal("stale h2 token was accepted")
	}
}

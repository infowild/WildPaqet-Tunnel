package client

import (
	"slices"
	"testing"
	"time"

	"paqet/internal/conf"
)

func TestEndpointCircuitBreakerHalfOpenProbe(t *testing.T) {
	cfg := &conf.TLS{
		BreakerFailures: 2,
		BreakerCooldown: 10 * time.Second,
		BreakerMax:      40 * time.Second,
	}
	pool := newEndpointPool(cfg)
	addrs := []string{"one:443", "two:443"}
	now := time.Now()

	pool.failure(addrs[0], now)
	pool.failure(addrs[0], now)
	if got := pool.candidates(addrs, 0, now.Add(time.Second)); slices.Contains(got, addrs[0]) {
		t.Fatalf("open endpoint returned as a candidate: %v", got)
	}

	got := pool.candidates(addrs, 0, now.Add(11*time.Second))
	if !slices.Contains(got, addrs[0]) {
		t.Fatalf("half-open probe not allowed after cooldown: %v", got)
	}
	got = pool.candidates(addrs, 0, now.Add(12*time.Second))
	if slices.Contains(got, addrs[0]) {
		t.Fatalf("second concurrent half-open probe was allowed: %v", got)
	}

	pool.success(addrs[0])
	got = pool.candidates(addrs, 0, now.Add(12*time.Second))
	if !slices.Contains(got, addrs[0]) {
		t.Fatalf("successful endpoint did not close its circuit: %v", got)
	}
}

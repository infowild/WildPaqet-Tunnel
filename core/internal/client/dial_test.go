package client

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestRetryDelayExponentialCappedAndJittered(t *testing.T) {
	if got, want := retryDelay(0, 0.5), time.Second; got != want {
		t.Fatalf("first retry = %s, want %s", got, want)
	}
	if got, want := retryDelay(4, 0.5), 16*time.Second; got != want {
		t.Fatalf("fifth retry = %s, want %s", got, want)
	}
	if got := retryDelay(20, 0.5); got != retryMax {
		t.Fatalf("capped retry = %s, want %s", got, retryMax)
	}
	if low, high := retryDelay(2, 0), retryDelay(2, 1); low != 3200*time.Millisecond || high != 4800*time.Millisecond {
		t.Fatalf("jitter range = [%s,%s], want [3.2s,4.8s]", low, high)
	}
}

func TestWaitRetryHonoursCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	start := time.Now()
	err := waitRetry(ctx, 0)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("waitRetry error = %v, want context canceled", err)
	}
	if elapsed := time.Since(start); elapsed > 100*time.Millisecond {
		t.Fatalf("cancelled retry waited too long: %s", elapsed)
	}
}

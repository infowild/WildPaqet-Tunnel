package client

import (
	"context"
	"sync"
	"testing"
	"time"

	"paqet/internal/conf"
	"paqet/internal/pkg/iterator"
)

func TestCandidateEnumerationDoesNotReserveUnusedFallback(t *testing.T) {
	p := newEndpointPool(&conf.TLS{BreakerFailures: 1, BreakerCooldown: time.Second, BreakerMax: time.Minute})
	now := time.Now()
	p.failure("backup:443", now)
	addrs := []string{"healthy:443", "backup:443"}
	for range 3 {
		got := p.candidates(addrs, 0, now.Add(2*time.Second))
		if len(got) != 2 {
			t.Fatalf("unused backup disappeared: %v", got)
		}
		if !p.acquire(got[0], now.Add(2*time.Second)) {
			t.Fatal("healthy endpoint unavailable")
		}
		p.success(got[0]) // caller returns here; backup must remain available
	}
	if !p.acquire("backup:443", now.Add(2*time.Second)) {
		t.Fatal("backup reservation leaked")
	}
	p.release("backup:443") // cancelled dial is not a network failure
	if !p.acquire("backup:443", now.Add(2*time.Second)) {
		t.Fatal("cancelled probe reservation leaked")
	}
}

func TestHalfOpenAcquireIsExclusive(t *testing.T) {
	p := newEndpointPool(&conf.TLS{BreakerFailures: 1, BreakerCooldown: time.Second, BreakerMax: time.Minute})
	now := time.Now()
	p.failure("backup", now)
	var wg sync.WaitGroup
	results := make(chan bool, 32)
	for range 32 {
		wg.Add(1)
		go func() { defer wg.Done(); results <- p.acquire("backup", now.Add(2*time.Second)) }()
	}
	wg.Wait()
	close(results)
	successes := 0
	for ok := range results {
		if ok {
			successes++
		}
	}
	if successes != 1 {
		t.Fatalf("concurrent probes: %d", successes)
	}
}

func TestUserSetupSkipsBusyPoolSlotAndNeverDials(t *testing.T) {
	busy := &timedConn{}
	healthy := &reconnectTestConn{}
	ready := &timedConn{conn: healthy}
	busy.mu.Lock()
	defer busy.mu.Unlock()
	c := &Client{cfg: &conf.Conf{Transport: conf.Transport{Protocol: "tls"}}, iter: &iterator.Iterator[*timedConn]{Items: []*timedConn{busy, ready}}}
	ctx, cancel := context.WithCancel(context.Background())
	conn, err := c.newConn(ctx)
	cancel()
	if err != nil || conn != healthy {
		t.Fatalf("healthy fallback: %v %v", conn, err)
	}
	if healthy.IsClosed() {
		t.Fatal("user cancellation closed shared session")
	}
}

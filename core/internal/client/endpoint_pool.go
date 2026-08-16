package client

import (
	"fmt"
	"sync"
	"time"

	"paqet/internal/conf"
)

type endpointState struct {
	failures  int
	openUntil time.Time
	probing   bool
}

// endpointPool is shared by all outer connections. It prevents every failed
// connection from repeatedly probing every endpoint during an outage.
type endpointPool struct {
	mu        sync.Mutex
	states    map[string]*endpointState
	threshold int
	base      time.Duration
	maximum   time.Duration
}

func newEndpointPool(cfg *conf.TLS) *endpointPool {
	return &endpointPool{
		states:    make(map[string]*endpointState),
		threshold: cfg.BreakerFailures,
		base:      cfg.BreakerCooldown,
		maximum:   cfg.BreakerMax,
	}
}

func (p *endpointPool) candidates(addrs []string, preferred int, now time.Time) []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	result := make([]string, 0, len(addrs))
	for offset := range addrs {
		addr := addrs[(preferred+offset)%len(addrs)]
		state := p.state(addr)
		if state.failures < p.threshold {
			result = append(result, addr)
			continue
		}
		if now.Before(state.openUntil) || state.probing {
			continue
		}
		// Only one half-open probe is allowed for an endpoint at a time.
		state.probing = true
		result = append(result, addr)
	}
	return result
}

func (p *endpointPool) success(addr string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	*p.state(addr) = endpointState{}
}

func (p *endpointPool) failure(addr string, now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	state := p.state(addr)
	state.probing = false
	state.failures++
	if state.failures < p.threshold {
		return
	}
	shift := state.failures - p.threshold
	if shift > 6 {
		shift = 6
	}
	cooldown := p.base << shift
	if cooldown > p.maximum {
		cooldown = p.maximum
	}
	state.openUntil = now.Add(cooldown)
}

func (p *endpointPool) state(addr string) *endpointState {
	state, ok := p.states[addr]
	if !ok {
		state = &endpointState{}
		p.states[addr] = state
	}
	return state
}

func (p *endpointPool) unavailableError(addrs []string, now time.Time) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	var earliest time.Time
	for _, addr := range addrs {
		until := p.state(addr).openUntil
		if earliest.IsZero() || until.Before(earliest) {
			earliest = until
		}
	}
	if earliest.After(now) {
		return fmt.Errorf("all TLS endpoints are circuit-open; earliest probe in %s", time.Until(earliest).Round(time.Second))
	}
	return fmt.Errorf("all TLS endpoints are unavailable")
}

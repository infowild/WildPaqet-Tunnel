package smux

import (
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func TestHeartbeatResamplesIntervalEveryProbe(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	go io.Copy(io.Discard, b)
	cfg := DefaultConfig()
	cfg.KeepAliveInterval = 10 * time.Millisecond
	cfg.KeepAliveTimeout = time.Second
	calls := make(chan int, 32)
	var count atomic.Int32
	cfg.KeepAliveIntervalFunc = func() time.Duration {
		n := int(count.Add(1))
		calls <- n
		if n%2 == 0 {
			return 5 * time.Millisecond
		}
		return 15 * time.Millisecond
	}
	s, e := Client(a, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	for want := 1; want <= 5; want++ {
		select {
		case n := <-calls:
			if n != want {
				t.Fatalf("callback sequence %d", n)
			}
		case <-time.After(time.Second):
			t.Fatal("interval was only sampled once")
		}
	}
}
func TestIdleHeartbeatStillDetectsUnresponsivePeer(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	go io.Copy(io.Discard, b)
	cfg := DefaultConfig()
	cfg.KeepAliveInterval = 5 * time.Millisecond
	cfg.KeepAliveTimeout = 40 * time.Millisecond
	cfg.KeepAliveOnIdle = true
	s, e := Client(a, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	select {
	case <-s.CloseChan():
	case <-time.After(time.Second):
		t.Fatal("unresponsive peer not closed")
	}
}
func TestActiveOutboundSuppressesRedundantNOP(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	cfg := DefaultConfig()
	cfg.KeepAliveInterval = 80 * time.Millisecond
	cfg.KeepAliveTimeout = time.Second
	cfg.KeepAliveOnIdle = true
	s, e := Client(a, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	atomic.StoreInt32(&s.outboundActive, 1)
	b.SetReadDeadline(time.Now().Add(120 * time.Millisecond))
	hdr := make([]byte, headerSize)
	if _, e = io.ReadFull(b, hdr); e == nil {
		t.Fatal("NOP despite outbound activity")
	}
	b.SetReadDeadline(time.Now().Add(time.Second))
	if _, e = io.ReadFull(b, hdr); e != nil {
		t.Fatal(e)
	}
	if hdr[1] != cmdNOP {
		t.Fatal("expected NOP")
	}
}

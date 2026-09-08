package forward

import (
	"context"
	"io"
	"net"
	"paqet/internal/tnet"
	"testing"
	"time"
)

type testStream struct{ net.Conn }

func (s testStream) SID() int { return 1 }

func TestTCPSetupAdmissionAndDeadline(t *testing.T) {
	started := make(chan struct{}, 1)
	f := &Forward{pending: make(chan struct{}, 1), connectTimeout: 100 * time.Millisecond, dialTCP: func(ctx context.Context, _ string) (tnet.Strm, error) {
		started <- struct{}{}
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go f.serveTCP(ctx, l)
	a, e := net.Dial("tcp", l.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	defer a.Close()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("setup not started")
	}
	b, e := net.Dial("tcp", l.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	defer b.Close()
	b.SetReadDeadline(time.Now().Add(time.Second))
	one := make([]byte, 1)
	if _, e = b.Read(one); e == nil {
		t.Fatal("excess connection accepted")
	} else if n, ok := e.(net.Error); ok && n.Timeout() {
		t.Fatal("excess connection queued")
	}
	a.SetReadDeadline(time.Now().Add(time.Second))
	if _, e = a.Read(one); e == nil {
		t.Fatal("expired connection still open")
	} else if n, ok := e.(net.Error); ok && n.Timeout() {
		t.Fatal("setup deadline not enforced")
	}
	select {
	case <-started:
		t.Fatal("second dial bypassed admission limit")
	default:
	}
}

func TestSetupDeadlineDoesNotKillActiveRelay(t *testing.T) {
	local, app := net.Pipe()
	defer app.Close()
	remote, echo := net.Pipe()
	defer echo.Close()
	f := &Forward{pending: make(chan struct{}, 1), connectTimeout: 30 * time.Millisecond, dialTCP: func(context.Context, string) (tnet.Strm, error) { return testStream{remote}, nil }}
	f.pending <- struct{}{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { defer close(done); defer local.Close(); f.handleTCPConn(ctx, local) }()
	go io.Copy(echo, echo)
	time.Sleep(80 * time.Millisecond)
	app.SetDeadline(time.Now().Add(time.Second))
	if _, e := app.Write([]byte("ping")); e != nil {
		t.Fatal(e)
	}
	got := make([]byte, 4)
	if _, e := io.ReadFull(app, got); e != nil {
		t.Fatal(e)
	}
	if string(got) != "ping" {
		t.Fatal("relay data changed")
	}
	cancel()
	app.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("relay did not stop")
	}
}

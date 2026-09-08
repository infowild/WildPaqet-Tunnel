package buffer

import (
	"bytes"
	"context"
	"io"
	"net"
	"testing"
	"time"
)

// halfPipe is a net.Conn pair stand-in for the tunnel stream side, which is a
// smux stream and has no half-close.
func halfPipe(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	a, b := net.Pipe()
	t.Cleanup(func() { _ = a.Close(); _ = b.Close() })
	return a, b
}

// TestRelayDeliversReplyAfterLocalHalfClose is the truncation regression: a
// client that finishes its upload and half-closes used to tear the whole pair
// down before the reply had been copied back.
func TestRelayDeliversReplyAfterLocalHalfClose(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	clientDone := make(chan []byte, 1)
	go func() {
		conn, err := net.Dial("tcp", listener.Addr().String())
		if err != nil {
			clientDone <- nil
			return
		}
		defer conn.Close()
		if _, err := conn.Write([]byte("request")); err != nil {
			clientDone <- nil
			return
		}
		// Half-close: upload finished, reply still outstanding.
		if err := conn.(*net.TCPConn).CloseWrite(); err != nil {
			clientDone <- nil
			return
		}
		reply, _ := io.ReadAll(conn)
		clientDone <- reply
	}()

	local, err := listener.Accept()
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	defer local.Close()

	stream, peer := halfPipe(t)
	reply := bytes.Repeat([]byte("reply-payload-"), 4096)
	go func() {
		got := make([]byte, len("request"))
		if _, err := io.ReadFull(peer, got); err != nil {
			return
		}
		// The far end answers only after the request is complete.
		time.Sleep(100 * time.Millisecond)
		_, _ = peer.Write(reply)
		_ = peer.Close()
	}()

	relayDone := make(chan error, 1)
	go func() {
		// Mirror the real call sites, which close both ends once Relay returns.
		defer local.Close()
		relayDone <- Relay(context.Background(), local, stream, 5*time.Second)
	}()

	select {
	case got := <-clientDone:
		if !bytes.Equal(got, reply) {
			t.Fatalf("reply truncated: got %d bytes, want %d", len(got), len(reply))
		}
	case <-time.After(10 * time.Second):
		t.Fatal("client never received the reply")
	}

	select {
	case <-relayDone:
	case <-time.After(5 * time.Second):
		t.Fatal("relay did not return after both directions ended")
	}
}

// TestRelayClosesLocalWriteWhenStreamEnds checks the other direction: the local
// peer must observe EOF once the tunnel stream is finished.
func TestRelayClosesLocalWriteWhenStreamEnds(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	sawEOF := make(chan error, 1)
	go func() {
		conn, err := net.Dial("tcp", listener.Addr().String())
		if err != nil {
			sawEOF <- err
			return
		}
		defer conn.Close()
		_, err = io.ReadAll(conn)
		sawEOF <- err
	}()

	local, err := listener.Accept()
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	defer local.Close()

	stream, peer := halfPipe(t)
	_ = peer.Close()

	go func() { _ = Relay(context.Background(), local, stream, time.Second) }()

	select {
	case err := <-sawEOF:
		if err != nil {
			t.Fatalf("local peer read: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("local peer never saw EOF after the stream ended")
	}
}

// TestRelayLingerIsBounded makes sure a peer that never closes cannot pin the
// relay open forever.
func TestRelayLingerIsBounded(t *testing.T) {
	local, localPeer := halfPipe(t)
	stream, streamPeer := halfPipe(t)

	go func() { _, _ = io.Copy(io.Discard, streamPeer) }()
	_ = localPeer.Close()

	done := make(chan struct{})
	start := time.Now()
	go func() {
		_ = Relay(context.Background(), local, stream, 200*time.Millisecond)
		close(done)
	}()

	select {
	case <-done:
		if elapsed := time.Since(start); elapsed < 150*time.Millisecond {
			t.Fatalf("relay returned after %s; the linger grace was skipped", elapsed)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("relay ignored its linger bound")
	}
}

func TestRelayHonoursContextCancellation(t *testing.T) {
	local, _ := halfPipe(t)
	stream, _ := halfPipe(t)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Relay(ctx, local, stream, time.Minute) }()
	cancel()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected the cancellation error")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("relay ignored context cancellation")
	}
}

func TestTCPBufferMatchesSmuxFrameSize(t *testing.T) {
	// smux's default MaxFrameSize is 32768; a smaller copy buffer splits every
	// read into extra frames, HTTP/2 DATA frames, TLS records and syscalls.
	if TCPSize != 32*1024 {
		t.Fatalf("TCPSize = %d, want 32768", TCPSize)
	}
}

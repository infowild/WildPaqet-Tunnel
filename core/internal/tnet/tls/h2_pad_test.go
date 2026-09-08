package tls

import (
	"bytes"
	"io"
	"math/rand"
	"net"
	"sync"
	"testing"
)

// countingConn records how long each Write to the wire was, which is what the
// TLS record length ends up reflecting.
type countingConn struct {
	net.Conn
	mu    sync.Mutex
	sizes []int
}

func (c *countingConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	c.sizes = append(c.sizes, len(p))
	c.mu.Unlock()
	return c.Conn.Write(p)
}

func TestPaddedConnRoundTripsExactly(t *testing.T) {
	a, b := net.Pipe()
	w := newPaddedConn(a)
	r := newPaddedConn(b)

	// Sizes on both sides of the padSmallFrame threshold, plus one that has to
	// be split across records.
	payloads := [][]byte{
		[]byte("x"),
		bytes.Repeat([]byte("k"), 8),
		bytes.Repeat([]byte("m"), padSmallFrame-1),
		bytes.Repeat([]byte("n"), padSmallFrame),
		bytes.Repeat([]byte("z"), padMaxChunk+1234),
	}
	var want []byte
	for _, p := range payloads {
		want = append(want, p...)
	}

	go func() {
		for _, p := range payloads {
			if _, err := w.Write(p); err != nil {
				return
			}
		}
		a.Close()
	}()

	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("round trip changed the bytes: got %d want %d", len(got), len(want))
	}
}

// The point of the whole layer: a repeated small write must not produce the
// same wire length every time.
func TestPaddedConnVariesSmallRecordLengths(t *testing.T) {
	client, server := net.Pipe()
	counted := &countingConn{Conn: client}
	w := newPaddedConn(counted)
	r := newPaddedConn(server)

	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, r)
		close(done)
	}()

	const rounds = 200
	heartbeat := bytes.Repeat([]byte{0}, 8) // the size of a smux keepalive
	for i := 0; i < rounds; i++ {
		if _, err := w.Write(heartbeat); err != nil {
			t.Fatal(err)
		}
	}
	client.Close()
	<-done

	counted.mu.Lock()
	defer counted.mu.Unlock()
	distinct := map[int]bool{}
	for _, s := range counted.sizes {
		distinct[s] = true
	}
	if len(distinct) < 50 {
		t.Fatalf("identical 8-byte writes produced only %d distinct wire lengths over %d records", len(distinct), rounds)
	}
}

// A bulk transfer must not pay for padding it does not need.
func TestPaddedConnLeavesLargeRecordsAlone(t *testing.T) {
	client, server := net.Pipe()
	counted := &countingConn{Conn: client}
	w := newPaddedConn(counted)
	r := newPaddedConn(server)

	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, r)
		close(done)
	}()

	bulk := bytes.Repeat([]byte("D"), 4096)
	for i := 0; i < 20; i++ {
		if _, err := w.Write(bulk); err != nil {
			t.Fatal(err)
		}
	}
	client.Close()
	<-done

	counted.mu.Lock()
	defer counted.mu.Unlock()
	for _, s := range counted.sizes {
		if s != len(bulk)+padHeaderSize {
			t.Fatalf("a %d-byte payload was written as %d bytes; large records must carry no filler", len(bulk), s)
		}
	}
}

// Reads of every shape must reassemble, including one byte at a time.
func TestPaddedConnSurvivesRaggedReads(t *testing.T) {
	a, b := net.Pipe()
	w := newPaddedConn(a)
	r := newPaddedConn(b)

	want := make([]byte, 40000)
	rnd := rand.New(rand.NewSource(1))
	rnd.Read(want)

	go func() {
		_, _ = w.Write(want)
		a.Close()
	}()

	got := make([]byte, 0, len(want))
	buf := make([]byte, 1)
	for {
		n, err := r.Read(buf)
		got = append(got, buf[:n]...)
		if err != nil {
			break
		}
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("byte-at-a-time read changed the payload (%d vs %d bytes)", len(got), len(want))
	}
}

package tls

import (
	"bytes"
	"errors"
	"io"
	"math/rand"
	"sync"
	"testing"
	"time"
)

func TestBufferedPipeRoundTripsAcrossWrap(t *testing.T) {
	// A capacity far smaller than the payload forces the ring to wrap many
	// times, which is where an off-by-one would corrupt the stream.
	p := newBufferedPipe(1024)
	reader := bufferedPipeReader{p: p}
	writer := bufferedPipeWriter{p: p}

	payload := make([]byte, 512*1024)
	if _, err := rand.New(rand.NewSource(1)).Read(payload); err != nil {
		t.Fatalf("seed payload: %v", err)
	}

	go func() {
		for offset := 0; offset < len(payload); {
			chunk := 1 + rand.Intn(4096)
			if offset+chunk > len(payload) {
				chunk = len(payload) - offset
			}
			if _, err := writer.Write(payload[offset : offset+chunk]); err != nil {
				return
			}
			offset += chunk
		}
		_ = writer.Close()
	}()

	got, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("read all: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("payload corrupted: got %d bytes, want %d", len(got), len(payload))
	}
}

func TestBufferedPipeDecouplesWriterFromReader(t *testing.T) {
	// The whole point of replacing io.Pipe: a write that fits in the buffer
	// must not wait for the reader to show up.
	p := newBufferedPipe(4096)
	writer := bufferedPipeWriter{p: p}

	done := make(chan struct{})
	go func() {
		defer close(done)
		if _, err := writer.Write(make([]byte, 4096)); err != nil {
			t.Errorf("write: %v", err)
		}
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("write blocked with no reader; buffer is not decoupling the loops")
	}
}

func TestBufferedPipeAppliesBackpressure(t *testing.T) {
	p := newBufferedPipe(1024)
	reader := bufferedPipeReader{p: p}
	writer := bufferedPipeWriter{p: p}

	blocked := make(chan struct{})
	go func() {
		_, _ = writer.Write(make([]byte, 4096))
		close(blocked)
	}()

	select {
	case <-blocked:
		t.Fatal("write past capacity returned without backpressure")
	case <-time.After(50 * time.Millisecond):
	}

	buf := make([]byte, 4096)
	read := 0
	for read < 4096 {
		n, err := reader.Read(buf)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		read += n
	}
	<-blocked
}

func TestBufferedPipeDrainsBeforeEOF(t *testing.T) {
	p := newBufferedPipe(4096)
	reader := bufferedPipeReader{p: p}
	writer := bufferedPipeWriter{p: p}

	if _, err := writer.Write([]byte("tail")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	got, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("read all: %v", err)
	}
	if string(got) != "tail" {
		t.Fatalf("buffered data lost on close: got %q", got)
	}
}

func TestBufferedPipeCloseReadUnblocksWriter(t *testing.T) {
	p := newBufferedPipe(1024)
	reader := bufferedPipeReader{p: p}
	writer := bufferedPipeWriter{p: p}

	sentinel := errors.New("gone")
	errCh := make(chan error, 1)
	go func() {
		_, err := writer.Write(make([]byte, 8192))
		errCh <- err
	}()

	time.Sleep(20 * time.Millisecond)
	_ = reader.CloseWithError(sentinel)

	select {
	case err := <-errCh:
		if !errors.Is(err, sentinel) {
			t.Fatalf("writer got %v, want %v", err, sentinel)
		}
	case <-time.After(time.Second):
		t.Fatal("writer stayed blocked after the read end closed")
	}
}

func TestBufferedPipeConcurrentWritersStayIntact(t *testing.T) {
	p := newBufferedPipe(2048)
	reader := bufferedPipeReader{p: p}
	writer := bufferedPipeWriter{p: p}

	const writers = 8
	const perWriter = 16 * 1024
	var wg sync.WaitGroup
	for i := 0; i < writers; i++ {
		wg.Add(1)
		go func(b byte) {
			defer wg.Done()
			chunk := bytes.Repeat([]byte{b}, perWriter)
			if _, err := writer.Write(chunk); err != nil {
				t.Errorf("write: %v", err)
			}
		}(byte('a' + i))
	}
	go func() {
		wg.Wait()
		_ = writer.Close()
	}()

	got, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("read all: %v", err)
	}
	if len(got) != writers*perWriter {
		t.Fatalf("got %d bytes, want %d", len(got), writers*perWriter)
	}
	counts := map[byte]int{}
	for _, b := range got {
		counts[b]++
	}
	for i := 0; i < writers; i++ {
		if counts[byte('a'+i)] != perWriter {
			t.Fatalf("writer %c delivered %d bytes, want %d", 'a'+i, counts[byte('a'+i)], perWriter)
		}
	}
}
